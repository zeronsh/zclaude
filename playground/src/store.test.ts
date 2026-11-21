import { test } from 'bun:test';
import assert from 'node:assert/strict';
import type { ZEvent } from '@zclaude/client/protocol';
import { SessionStore } from '@zclaude/client/store';
import { buildRows, newMemo, rowsToText } from './model.ts';

const ev = (method: string, params: Record<string, unknown>, seq: number): ZEvent => ({ method, params: { seq, ...params } }) as ZEvent;

test('protocol events from zclaude build the conversation, live then confirmed, in one row', () => {
  const store = new SessionStore();
  const memo = newMemo();
  const events = [
    ev('state', { state: 'idle', previous: 'starting' }, 1),
    ev('prompt', { id: 'p1', text: 'hi', transport: 'inproc', status: 'delivered' }, 2),
    ev('entry', { uuid: 'u1', session_id: 's', role: 'user', origin: 'external', timestamp: '2026-11-21T00:00:00Z', text: 'hi', blocks: [{ type: 'text', text: 'hi' }], prompt_id: 'p1', sidechain: false }, 3),
    ev('prompt', { id: 'p1', text: 'hi', transport: 'inproc', status: 'received' }, 4),
    ev('state', { state: 'busy', previous: 'idle' }, 5),
    ev('stream.start', { stream: 1, message_id: 'm1', model: 'haiku', main: true, in_thread: true, in_transcript: false, started_at: 1 }, 6),
    ev('stream.block', { stream: 1, index: 0, type: 'text', started_at: 1 }, 7),
    ev('stream.delta', { stream: 1, index: 0, text: 'Hel' }, 8),
  ];
  for (const event of events) store.apply(event);
  const live = buildRows(store.view, Date.now(), memo);
  assert.equal(rowsToText(live.rows), 'hi\nfrom chat · in-process\nHel');
  assert.equal(live.working, true);
  const key = live.rows[1]!.key;

  store.apply(ev('stream.delta', { stream: 1, index: 0, text: 'lo' }, 9));
  store.apply(ev('stream.end', { stream: 1, status: 'done', ended_at: Date.now() }, 10));
  store.apply(ev('entry', { uuid: 'u2', session_id: 's', role: 'assistant', origin: 'assistant', timestamp: '2026-11-21T00:00:01Z', text: 'Hello', blocks: [{ type: 'text', text: 'Hello' }], message_id: 'm1', sidechain: false }, 11));
  store.apply(ev('stream.confirmed', { stream: 1, message_id: 'm1' }, 12));
  store.apply(ev('state', { state: 'idle', previous: 'busy' }, 13));
  const done = buildRows(store.view, Date.now(), memo);
  assert.equal(rowsToText(done.rows), 'hi\nfrom chat · in-process\nHello');
  assert.equal(done.rows[1]!.key, key, 'the reply grew in place');
  assert.equal(done.working, false);
});

test('a replayed entry is not shown twice', () => {
  const store = new SessionStore();
  const entry = { uuid: 'u1', session_id: 's', role: 'user', origin: 'terminal', timestamp: 't', text: 'typed', blocks: [], sidechain: false };
  store.apply(ev('entry', entry, 1));
  store.apply(ev('entry', { ...entry, historic: true }, 2));
  assert.equal(buildRows(store.view, 0, newMemo()).rows.length, 1);
});
