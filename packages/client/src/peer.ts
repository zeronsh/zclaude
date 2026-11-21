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

export class Peer {
  #nextId = 0;
  #pending = new Map<number, Pending>();
  #listeners = new Map<string, Set<(params: any) => void>>();
  #any = new Set<(event: ZEvent) => void>();
  #buffer = '';
  #closed = false;

  constructor(private readonly writeLine: (line: string) => void) {}

  /** Feed raw text as it arrives; complete lines are dispatched. */
  feed(chunk: string): void {
    this.#buffer += chunk;
    let end: number;
    while ((end = this.#buffer.indexOf('\n')) >= 0) {
      const line = this.#buffer.slice(0, end);
      this.#buffer = this.#buffer.slice(end + 1);
      if (line.trim()) this.handleLine(line);
    }
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
    if (this.#closed) return Promise.reject(new Error('zclaude connection is closed'));
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
      const timer = setTimeout(() => {
        off();
        reject(new Error(`timed out waiting for ${type}`));
      }, timeoutMs);
      const off = this.on(type, (params) => {
        if (!predicate(params)) return;
        clearTimeout(timer);
        off();
        resolve(params);
      });
    });
  }

  close(reason = 'zclaude connection closed'): void {
    if (this.#closed) return;
    this.#closed = true;
    for (const pending of this.#pending.values()) pending.reject(new Error(reason));
    this.#pending.clear();
  }

  get closed(): boolean {
    return this.#closed;
  }
}
