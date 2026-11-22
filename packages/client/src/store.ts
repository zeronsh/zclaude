// An optional, in-memory store for consumers that want the session as one value,
// such as a UI. zclaude itself keeps nothing; this is one way a consumer can.
// Browser-safe: no Node imports.
import type { Activity, AgentInfo, BackgroundTask, DialogInfo, DialogStatus, DialogUpdate, Entry, Meta, SessionState, Snapshot, TurnEnd, Usage, ZEvent } from './protocol.ts';

export interface StreamView {
  message_id?: string;
  model?: string;
  status: 'streaming' | 'done' | 'aborted';
  started_at: number;
  ended_at?: number;
  /** Part of the main conversation, as opposed to a subagent or background call. */
  main?: boolean;
  in_transcript?: boolean;
  stop_reason?: string;
  usage?: Usage;
  blocks: Array<{ index: number; type: string; name?: string; text: string; started_at?: number; ended_at?: number }>;
}

/** A dialog as last reported: open, or how it closed. */
export interface DialogView extends Omit<DialogInfo, 'status'> {
  status: DialogStatus;
  resolved_by?: DialogUpdate['resolved_by'];
  answers?: Record<string, string>;
}

export interface PromptView {
  id: string;
  text: string;
  transport: string;
  status: string;
  error?: string;
}

export interface SessionView {
  state: SessionState | 'connecting';
  meta: Partial<Meta>;
  entries: Entry[];
  streams: Record<string, StreamView>;
  prompts: Record<string, PromptView>;
  dialogs: Record<string, DialogView>;
  term: { cols: number; rows: number };
  activity: Activity;
  /** The turn in progress. */
  turn: { turn: number; claude_prompt_id?: string; started_at: number } | null;
  /** How the last turn ended. */
  lastTurn: TurnEnd | null;
  tasks: BackgroundTask[];
  /** Subagents running now, by id. */
  agents: Record<string, AgentInfo>;
  exitCode?: number;
  exitSignal?: string;
  seq: number;
}

export interface StoreOptions {
  /**
   * Keep at most this many entries, dropping the oldest. Unbounded by default; a
   * long-running consumer should set it.
   */
  maxEntries?: number;
  /**
   * Drop a finished stream's text once the transcript holds its message (the entry
   * carries the same text). Timings are kept. Default true.
   */
  pruneStreams?: boolean;
}

export const OPEN_DIALOG = new Set<string>(['open']);

export class SessionStore {
  #state: SessionView['state'] = 'connecting';
  #meta: Partial<Meta> = {};
  #entries: Entry[] = [];
  #uuids = new Set<string>();
  #streams: Record<string, StreamView> = {};
  #prompts: Record<string, PromptView> = {};
  #dialogs: Record<string, DialogView> = {};
  #term = { cols: 0, rows: 0 };
  #activity: Activity = { activity: 'starting', since: 0 };
  #turn: SessionView['turn'] = null;
  #lastTurn: TurnEnd | null = null;
  #tasks: BackgroundTask[] = [];
  #agents: Record<string, AgentInfo> = {};
  #exitCode?: number;
  #exitSignal?: string;
  #seq = 0;
  #view?: SessionView;
  #listeners = new Set<() => void>();
  readonly #maxEntries: number;
  readonly #pruneStreams: boolean;

  constructor(options: StoreOptions = {}) {
    this.#maxEntries = options.maxEntries ?? Infinity;
    this.#pruneStreams = options.pruneStreams ?? true;
  }

  /** Takes in the state a session reports on `ready`, `status` or `subscribe`. */
  load(snapshot: Snapshot): void {
    this.#state = snapshot.state;
    this.#meta = { ...this.#meta, ...snapshot.meta };
    this.#term = snapshot.term;
    this.#seq = Math.max(this.#seq, snapshot.seq);
    if (snapshot.activity) this.#activity = snapshot.activity;
    if (snapshot.turn !== undefined) this.#turn = snapshot.turn;
    if (snapshot.tasks) this.#tasks = snapshot.tasks;
    if (snapshot.agents) this.#agents = Object.fromEntries(snapshot.agents.map((agent) => [agent.agent_id, agent]));
    const dialogs = { ...this.#dialogs };
    for (const dialog of snapshot.dialogs) dialogs[dialog.id] = { ...dialog };
    this.#dialogs = dialogs;
    const prompts = { ...this.#prompts };
    for (const prompt of snapshot.prompts) prompts[prompt.id] = { ...prompt };
    this.#prompts = prompts;
    const streams = { ...this.#streams };
    for (const stream of snapshot.streams) {
      streams[`s${stream.stream}`] = {
        message_id: stream.message_id,
        model: stream.model,
        status: stream.status,
        started_at: stream.started_at,
        main: stream.main,
        usage: stream.usage,
        blocks: stream.blocks.map((block) => ({ ...block })),
      };
    }
    this.#streams = streams;
    this.#changed();
  }

  /** Replaces everything with a view from `view` (of this or another store). */
  restore(view: SessionView): void {
    this.#state = view.state;
    this.#meta = view.meta;
    this.#entries = view.entries;
    this.#uuids = new Set(view.entries.map((entry) => entry.uuid));
    this.#streams = view.streams;
    this.#prompts = view.prompts;
    this.#dialogs = view.dialogs;
    this.#term = view.term;
    this.#activity = view.activity;
    this.#turn = view.turn;
    this.#lastTurn = view.lastTurn;
    this.#tasks = view.tasks;
    this.#agents = view.agents;
    this.#exitCode = view.exitCode;
    this.#exitSignal = view.exitSignal;
    this.#seq = view.seq;
    this.#changed();
  }

  apply(event: ZEvent): void {
    const p: any = event.params;
    if (typeof p.seq === 'number') this.#seq = Math.max(this.#seq, p.seq);
    switch (event.method) {
      case 'ready':
        this.load(p.snapshot);
        return;
      case 'state':
        this.#state = p.state;
        break;
      case 'meta': {
        const { seq: _, ...changes } = p;
        this.#meta = { ...this.#meta, ...changes };
        break;
      }
      case 'entry':
        if (this.#uuids.has(p.uuid)) return;
        this.#uuids.add(p.uuid);
        this.#entries = [...this.#entries, p];
        if (this.#entries.length > this.#maxEntries) {
          const dropped = this.#entries.slice(0, this.#entries.length - this.#maxEntries);
          this.#entries = this.#entries.slice(-this.#maxEntries);
          for (const entry of dropped) this.#uuids.delete(entry.uuid);
          this.#dropStreamsOf(dropped);
        }
        if (this.#pruneStreams && p.message_id) this.#pruneMessage(p.message_id);
        break;
      case 'prompt':
        this.#prompts = { ...this.#prompts, [p.id]: { id: p.id, text: p.text, transport: p.transport, status: p.status, error: p.error } };
        break;
      case 'stream.start':
        this.#setStream(p.stream, (s) => ({
          ...s,
          message_id: p.message_id,
          model: p.model,
          main: p.main,
          in_transcript: p.in_transcript || s.in_transcript,
          started_at: p.started_at,
          usage: p.usage,
        }));
        break;
      case 'stream.usage':
        this.#setStream(p.stream, (s) => ({ ...s, usage: p.usage }));
        break;
      case 'activity': {
        const { seq: _, ...activity } = p;
        this.#activity = activity;
        break;
      }
      case 'turn.start':
        this.#turn = { turn: p.turn, claude_prompt_id: p.claude_prompt_id, started_at: p.started_at };
        break;
      case 'turn.end': {
        const { seq: _, ...end } = p;
        this.#lastTurn = end;
        if (this.#turn?.turn === p.turn) this.#turn = null;
        break;
      }
      case 'tasks':
        this.#tasks = p.tasks;
        break;
      case 'agent.start': {
        const { seq: _, ...agent } = p;
        this.#agents = { ...this.#agents, [p.agent_id]: agent };
        break;
      }
      case 'agent.stop': {
        const { [p.agent_id]: _gone, ...rest } = this.#agents;
        this.#agents = rest;
        break;
      }
      case 'stream.block':
        this.#setStream(p.stream, (s) => ({ ...s, blocks: [...s.blocks, { index: p.index, type: p.type, name: p.name, text: '', started_at: p.started_at }] }));
        break;
      case 'stream.delta':
        this.#setStream(p.stream, (s) => ({
          ...s,
          blocks: s.blocks.map((block) => (block.index === p.index ? { ...block, text: block.text + p.text } : block)),
        }));
        break;
      case 'stream.block_stop':
        this.#setStream(p.stream, (s) => ({
          ...s,
          blocks: s.blocks.map((block) => (block.index === p.index ? { ...block, ended_at: p.ended_at } : block)),
        }));
        break;
      case 'stream.stop_reason':
        this.#setStream(p.stream, (s) => ({ ...s, stop_reason: p.stop_reason }));
        break;
      case 'stream.end':
        this.#setStream(p.stream, (s) => this.#pruned({ ...s, status: p.status, ended_at: p.ended_at }));
        break;
      case 'stream.confirmed':
        this.#setStream(p.stream, (s) => this.#pruned({ ...s, in_transcript: true, ...(p.main !== undefined && { main: p.main }) }));
        break;
      case 'dialog.open': {
        const { seq: _, ...dialog } = p as DialogInfo & { seq: number };
        this.#dialogs = { ...this.#dialogs, [p.id]: dialog };
        break;
      }
      case 'dialog.update': {
        const current = this.#dialogs[p.id];
        if (!current) return;
        const update = p as DialogUpdate;
        const next: DialogView = { ...current, status: update.status };
        if (update.resolved_by !== undefined) next.resolved_by = update.resolved_by;
        if (update.answers !== undefined) next.answers = update.answers;
        if (update.held !== undefined) next.held = update.held;
        if (update.touched !== undefined) next.touched = update.touched;
        if (update.modes !== undefined) next.modes = update.modes;
        this.#dialogs = { ...this.#dialogs, [p.id]: next };
        break;
      }
      case 'term.resize':
        this.#term = { cols: p.cols, rows: p.rows };
        break;
      case 'exit':
        this.#exitCode = p.code;
        this.#exitSignal = p.signal;
        this.#state = 'exited';
        this.#activity = { activity: 'exited', since: Date.now() };
        break;
      default:
        return;
    }
    this.#changed();
  }

  #setStream(n: number, update: (stream: StreamView) => StreamView): void {
    const key = `s${n}`;
    const current = this.#streams[key] ?? { status: 'streaming', started_at: Date.now(), blocks: [] };
    this.#streams = { ...this.#streams, [key]: update(current) };
  }

  /** A finished stream the transcript holds keeps its timings, not its text. */
  #pruned(stream: StreamView): StreamView {
    if (!this.#pruneStreams || stream.status !== 'done' || !stream.in_transcript) return stream;
    if (stream.blocks.every((block) => block.text === '')) return stream;
    return { ...stream, blocks: stream.blocks.map((block) => ({ ...block, text: '' })) };
  }

  #pruneMessage(messageId: string): void {
    for (const [key, stream] of Object.entries(this.#streams)) {
      if (stream.message_id !== messageId) continue;
      const next = this.#pruned({ ...stream, in_transcript: true });
      if (next !== stream) this.#streams = { ...this.#streams, [key]: next };
    }
  }

  #dropStreamsOf(entries: Entry[]): void {
    const ids = new Set(entries.map((entry) => entry.message_id).filter(Boolean));
    if (!ids.size) return;
    const streams: Record<string, StreamView> = {};
    for (const [key, stream] of Object.entries(this.#streams)) {
      if (!(stream.message_id && ids.has(stream.message_id) && stream.status !== 'streaming')) streams[key] = stream;
    }
    this.#streams = streams;
  }

  #changed(): void {
    this.#view = undefined;
    for (const listener of this.#listeners) listener();
  }

  /** The current value. The same object until something changes. */
  get view(): SessionView {
    return (this.#view ??= {
      state: this.#state,
      meta: this.#meta,
      entries: this.#entries,
      streams: this.#streams,
      prompts: this.#prompts,
      dialogs: this.#dialogs,
      term: this.#term,
      activity: this.#activity,
      turn: this.#turn,
      lastTurn: this.#lastTurn,
      tasks: this.#tasks,
      agents: this.#agents,
      exitCode: this.#exitCode,
      exitSignal: this.#exitSignal,
      seq: this.#seq,
    });
  }

  subscribe(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
}
