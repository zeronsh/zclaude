// Transport-agnostic JSON-RPC peer: feed it lines, give it a way to write lines.
// Works over a child's stdio, a Unix socket, or a WebSocket relay in a browser.
import type { EventMap, EventType, Method, Methods, ZEvent } from './protocol.ts';

export class RpcError extends Error {
  constructor(
    message: string,
    readonly code: number,
  ) {
    super(message);
    this.name = 'RpcError';
  }
}

type Pending = { resolve: (value: any) => void; reject: (error: Error) => void };

/** `connecting` until the transport can carry messages, `closed` once it can't. */
export type PeerState = 'connecting' | 'open' | 'closed';

export class Peer {
  #nextId = 0;
  #pending = new Map<number, Pending>();
  #listeners = new Map<string, Set<(params: any) => void>>();
  #any = new Set<(event: ZEvent) => void>();
  #stateListeners = new Set<(state: PeerState) => void>();
  #buffer = '';
  #state: PeerState = 'connecting';
  #closeReason = '';
  #settleOpen!: { resolve: () => void; reject: (error: Error) => void };

  /** Resolves once the transport is open; rejects if it closes first. */
  readonly opened: Promise<void>;

  constructor(private readonly writeLine: (line: string) => void) {
    this.opened = new Promise<void>((resolve, reject) => (this.#settleOpen = { resolve, reject }));
    // Nobody has to wait on `opened`, so a close before opening isn't unhandled.
    this.opened.catch(() => {});
  }

  /** Called by the transport once messages can flow. */
  markOpen(): void {
    if (this.#state !== 'connecting') return;
    this.#setState('open');
    this.#settleOpen.resolve();
  }

  get state(): PeerState {
    return this.#state;
  }

  /** Why the connection closed, once it has. */
  get closeReason(): string {
    return this.#closeReason;
  }

  /** Called with every change of `state`. */
  onStateChange(listener: (state: PeerState) => void): () => void {
    this.#stateListeners.add(listener);
    return () => this.#stateListeners.delete(listener);
  }

  #setState(state: PeerState): void {
    this.#state = state;
    for (const listener of this.#stateListeners) listener(state);
  }

  /** Feed raw text as it arrives; complete lines are dispatched. */
  feed(chunk: string): void {
    // Only the new text is searched, so a long line arriving in pieces stays linear.
    let from = this.#buffer.length;
    this.#buffer += chunk;
    let start = 0;
    let end: number;
    while ((end = this.#buffer.indexOf('\n', from)) >= 0) {
      const line = this.#buffer.slice(start, end);
      start = from = end + 1;
      if (line.trim()) this.handleLine(line);
    }
    if (start > 0) this.#buffer = this.#buffer.slice(start);
  }

  handleLine(line: string): void {
    let message: any;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id !== undefined && message.id !== null && !message.method) {
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      if (message.error) pending.reject(new RpcError(message.error.message ?? 'error', message.error.code ?? -32000));
      else pending.resolve(message.result);
      return;
    }
    if (typeof message.method === 'string') {
      const event = { method: message.method, params: message.params ?? {} } as ZEvent;
      for (const listener of this.#any) listener(event);
      for (const listener of this.#listeners.get(message.method) ?? []) listener(event.params);
    }
  }

  call<M extends Method>(method: M, ...args: Methods[M][0] extends undefined ? [params?: Methods[M][0]] : [params: Methods[M][0]]): Promise<Methods[M][1]>;
  call(method: string, params?: unknown): Promise<any>;
  call(method: string, params?: unknown): Promise<any> {
    if (this.#state === 'closed') return Promise.reject(new Error(this.#closeReason || 'zclaude connection is closed'));
    const id = ++this.#nextId;
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      this.writeLine(JSON.stringify({ jsonrpc: '2.0', id, method, params: params ?? {} }));
    });
  }

  on<E extends EventType>(type: E, listener: (params: EventMap[E] & { seq: number }) => void): () => void {
    let set = this.#listeners.get(type);
    if (!set) this.#listeners.set(type, (set = new Set()));
    set.add(listener);
    return () => set!.delete(listener);
  }

  onEvent(listener: (event: ZEvent) => void): () => void {
    this.#any.add(listener);
    return () => this.#any.delete(listener);
  }

  /** Resolves with the first event of `type` that matches. */
  waitFor<E extends EventType>(type: E, predicate: (params: EventMap[E] & { seq: number }) => boolean = () => true, timeoutMs = 60_000): Promise<EventMap[E] & { seq: number }> {
    return new Promise((resolve, reject) => {
      if (this.#state === 'closed') return reject(new Error(this.#closeReason));
      const done = () => {
        clearTimeout(timer);
        off();
        offState();
      };
      const timer = setTimeout(() => {
        done();
        reject(new Error(`timed out waiting for ${type}`));
      }, timeoutMs);
      const off = this.on(type, (params) => {
        if (!predicate(params)) return;
        done();
        resolve(params);
      });
      const offState = this.onStateChange((state) => {
        if (state !== 'closed') return;
        done();
        reject(new Error(this.#closeReason));
      });
    });
  }

  /** Marks the connection closed: pending calls fail, and so do later ones. */
  close(reason = 'zclaude connection closed'): void {
    if (this.#state === 'closed') return;
    this.#closeReason = reason;
    this.#setState('closed');
    this.#settleOpen.reject(new Error(reason));
    for (const pending of this.#pending.values()) pending.reject(new Error(reason));
    this.#pending.clear();
  }

  get closed(): boolean {
    return this.#state === 'closed';
  }
}
