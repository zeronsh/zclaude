// An optional, in-memory store for consumers that want the session as one value,
// such as a UI. zclaude itself keeps nothing; this is one way a consumer can.
// Browser-safe: no Node imports.
import type { DialogInfo, DialogStatus, DialogUpdate, Entry, Meta, SessionState, Snapshot, ZEvent } from './protocol.ts';

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
        }));
        break;
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
        this.#setStream(p.stream, (s) => this.#pruned({ ...s, in_transcript: true }));
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
