// An optional, in-memory store for consumers that want the session as one value,
// such as a UI. zclaude itself keeps nothing; this is one way a consumer can.
// Browser-safe: no Node imports.
import type { Entry, Meta, SessionState, Snapshot, ZEvent } from './protocol.ts';

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

export interface DialogView {
  id: string;
  kind: 'question' | 'permission' | 'plan' | 'elicitation';
  tool: string;
  input: any;
  suggestions: any[];
  status: string;
  created_at: number;
  held: boolean;
  touched: boolean;
  resolved_by?: string;
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
  seq: number;
}

export const OPEN_DIALOG = new Set(['open', 'answering']);

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
  #seq = 0;
  #view?: SessionView;
  #listeners = new Set<() => void>();

  /** Takes in the state a session reports on `ready`, `status` or `subscribe`. */
  load(snapshot: Snapshot): void {
    this.#state = snapshot.state;
    this.#meta = { ...this.#meta, ...snapshot.meta };
    this.#term = snapshot.term;
    this.#seq = Math.max(this.#seq, snapshot.seq);
    for (const dialog of snapshot.dialogs) this.#dialogs[dialog.id] = { ...dialog };
    for (const prompt of snapshot.prompts) this.#prompts[prompt.id] = { ...prompt };
    for (const stream of snapshot.streams) {
      this.#streams[`s${stream.stream}`] = {
        message_id: stream.message_id,
        model: stream.model,
        status: stream.status,
        started_at: stream.started_at,
        main: stream.main,
        blocks: stream.blocks.map((block) => ({ ...block })),
      };
    }
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
        this.#setStream(p.stream, (s) => ({ ...s, status: p.status, ended_at: p.ended_at }));
        break;
      case 'stream.confirmed':
        this.#setStream(p.stream, (s) => ({ ...s, in_transcript: true }));
        break;
      case 'dialog.open': {
        const { seq: _, ...dialog } = p;
        this.#dialogs = { ...this.#dialogs, [p.id]: dialog };
        break;
      }
      case 'dialog.update': {
        const current = this.#dialogs[p.id];
        if (!current) return;
        const { seq: _, id: __, ...changes } = p;
        this.#dialogs = { ...this.#dialogs, [p.id]: { ...current, ...changes } };
        break;
      }
      case 'term.resize':
        this.#term = { cols: p.cols, rows: p.rows };
        break;
      case 'exit':
        this.#exitCode = p.code;
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
      seq: this.#seq,
    });
  }

  subscribe(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
}
