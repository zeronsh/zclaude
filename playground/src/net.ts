// The browser's side of the playground server: one WebSocket carrying zclaude's
// events, terminal output and RPC replies.
import type { Method, Methods, ZEvent } from '@zclaude/client/protocol';
import { SessionStore, type SessionView } from '@zclaude/client/store';

// The token from the URL authorizes the socket (the page itself sets a cookie too).
export const token = new URLSearchParams(location.search).get('t') ?? '';

const wsUrl = (): string => `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws?t=${encodeURIComponent(token)}`;

/** Replaced wholesale when the session restarts, so nothing stale carries over. */
export let store = new SessionStore();
const storeListeners = new Set<() => void>();
const termListeners = new Set<(data: Uint8Array, redraw: boolean) => void>();
export let bytesReceived = 0;

let socket: WebSocket | null = null;
let nextId = 0;
const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();

function resetStore(): void {
  store = new SessionStore();
  for (const listener of storeListeners) listener();
}

export function onStoreReplaced(listener: () => void): () => void {
  storeListeners.add(listener);
  return () => storeListeners.delete(listener);
}

const connectedListeners = new Set<() => void>();

/** Runs on every (re)connection, once replies can flow. */
export function onConnected(listener: () => void): () => void {
  connectedListeners.add(listener);
  if (socket?.readyState === WebSocket.OPEN) listener();
  return () => connectedListeners.delete(listener);
}

export function onTerminal(listener: (data: Uint8Array, redraw: boolean) => void): () => void {
  termListeners.add(listener);
  return () => termListeners.delete(listener);
}

const fromBase64 = (data: string): Uint8Array => Uint8Array.from(atob(data), (c) => c.charCodeAt(0));

export const toBase64 = (bytes: Uint8Array): string => {
  let text = '';
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
};

export function connect(): void {
  socket = new WebSocket(wsUrl());
  socket.onopen = () => {
    for (const listener of connectedListeners) listener();
  };
  socket.onmessage = (message) => {
    bytesReceived += typeof message.data === 'string' ? message.data.length : 0;
    const data = JSON.parse(message.data as string);
    switch (data.type) {
      case 'replay':
        resetStore();
        store.restore(data.view as SessionView);
        break;
      case 'restarted':
        resetStore();
        for (const listener of termListeners) listener(new TextEncoder().encode('\x1bc'), true);
        break;
      case 'event':
        store.apply(data.event as ZEvent);
        break;
      case 'exited':
        // zclaude's `exit` event normally came first; this covers it dying without one.
        if (store.view.state !== 'exited') store.apply({ method: 'exit', params: { seq: 0, code: data.code ?? -1 } });
        break;
      case 'term':
        for (const listener of termListeners) listener(fromBase64(data.data), Boolean(data.redraw));
        break;
      case 'reply': {
        const waiter = pending.get(data.id);
        if (!waiter) break;
        pending.delete(data.id);
        if (data.error) waiter.reject(new Error(data.error));
        else waiter.resolve(data.result);
        break;
      }
    }
  };
  socket.onclose = () => {
    for (const waiter of pending.values()) waiter.reject(new Error('disconnected'));
    pending.clear();
    setTimeout(connect, 1500);
  };
}

export function rpc<M extends Method>(method: M, params?: Methods[M][0]): Promise<Methods[M][1]>;
export function rpc(method: 'playground.restart'): Promise<true>;
export function rpc(method: string, params: unknown = {}): Promise<any> {
  if (socket?.readyState !== WebSocket.OPEN) return Promise.reject(new Error('not connected to the playground server'));
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    socket!.send(JSON.stringify({ id, method, params: params ?? {} }));
  });
}

/** Browser storage can be unavailable, and these settings are only conveniences. */
export const stored = (key: string, fallback: string): string => {
  try {
    return localStorage.getItem(key) ?? fallback;
  } catch {
    return fallback;
  }
};

export const remember = (key: string, value: string): void => {
  try {
    localStorage.setItem(key, value);
  } catch {}
};
