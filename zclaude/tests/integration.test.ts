// Drives real Claude Code sessions on Haiku through zclaude's public protocol, the
// way any consumer would. Needs a logged-in `claude` on PATH, a built binary (`make`
// in zclaude/) and python3 for the terminal host. Run from the repo root:
// `bun test --timeout 240000 zclaude/tests`. Prompts are kept short: this spends
// real tokens.
//
// Event order across sources is not guaranteed. Hooks, the transcript and the token
// stream reach zclaude independently, so an assistant `entry` can arrive after the
// `state: idle` that ends its turn. Tests wait for each thing they need explicitly.
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { ZClaude, SessionStore, type EventMap, type EventType, type ZEvent } from '../../packages/client/src/index.ts';

const BIN = process.env.ZCLAUDE_BIN ?? resolve(import.meta.dir, '../bin/zclaude');

// `/model` saves the chosen model as the user's default for new sessions, in
// ~/.claude/settings.json. The suite puts that file back as it found it.
const USER_SETTINGS = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude'), 'settings.json');
const savedSettings = existsSync(USER_SETTINGS) ? readFileSync(USER_SETTINGS) : null;
afterAll(() => {
  if (savedSettings) writeFileSync(USER_SETTINGS, savedSettings);
  else rmSync(USER_SETTINGS, { force: true });
});
const FIXTURES = resolve(import.meta.dir, 'fixtures');
const MODEL = process.env.ZCLAUDE_TEST_MODEL ?? 'haiku';
const TURN = 120_000;

class Log {
  events: ZEvent[] = [];
  constructor(z: ZClaude) {
    z.onEvent((event) => this.events.push(event));
  }
  mark(): number {
    return this.events.length;
  }
  async wait<E extends EventType>(type: E, predicate: (p: EventMap[E] & { seq: number }) => boolean = () => true, since = 0, timeout = TURN): Promise<EventMap[E] & { seq: number }> {
    const started = Date.now();
    let i = since;
    while (Date.now() - started < timeout) {
      for (; i < this.events.length; i++) {
        const event = this.events[i]!;
        if (event.method === type && predicate(event.params as any)) return event.params as any;
      }
      await Bun.sleep(25);
    }
    const tail = this.events.slice(-20).map((e) => `${e.method}${'state' in e.params ? `:${(e.params as any).state}` : ''}`);
    throw new Error(`timed out waiting for ${type}. Last events: ${tail.join(', ')}`);
  }
  since(mark: number, type?: EventType): ZEvent[] {
    return this.events.slice(mark).filter((e) => !type || e.method === type);
  }
}

async function until(check: () => boolean | Promise<boolean>, timeout = 30_000, what = 'condition'): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (await check()) return;
    await Bun.sleep(100);
  }
  throw new Error(`timed out waiting for ${what}`);
}

interface Session {
  z: ZClaude;
  log: Log;
  store: SessionStore;
  dir: string;
}

// ZCLAUDE_TEST_DEBUG=DIR keeps zclaude's and Claude Code's debug logs there.
const DEBUG_DIR = process.env.ZCLAUDE_TEST_DEBUG;

async function start(args: string[]): Promise<Session> {
  const dir = mkdtempSync(join(tmpdir(), 'zclaude-it-'));
  const name = dir.split('/').at(-1)!;
  const debug = DEBUG_DIR ? ['--debug-file', join(DEBUG_DIR, `${name}.claude.log`)] : [];
  const z = ZClaude.spawn({
    bin: BIN,
    cwd: dir,
    args: ['--model', MODEL, ...debug, ...args],
    cols: 120,
    rows: 40,
    log: DEBUG_DIR ? join(DEBUG_DIR, `${name}.zclaude.log`) : undefined,
  });
  const log = new Log(z);
  const store = new SessionStore();
  z.onEvent((event) => store.apply(event));
  await z.ready;
  await log.wait('state', (p) => p.state === 'idle', 0, 60_000);
  return { z, log, store, dir };
}

async function stop(session?: Session): Promise<void> {
  if (!session) return;
  await session.z.shutdown();
  rmSync(session.dir, { recursive: true, force: true });
}

/**
 * Sends a prompt and waits for the turn that takes it in to end. `turn.end` comes
 * after every entry of its turn (zclaude waits for the transcript's own end
 * marker), unlike `state: idle`, which can come before the last entry.
 */
async function turn(s: Session, text: string): Promise<{ mark: number; reply: string; end: EventMap['turn.end'] }> {
  const mark = s.log.mark();
  const sent = await s.z.send(text);
  const end = await s.log.wait('turn.end', (p) => p.prompt_ids.includes(sent.prompt_id), mark);
  const replies = s.log.since(mark, 'entry').map((e) => e.params as EventMap['entry']).filter((e) => e.role === 'assistant' && !e.sidechain);
  return { mark, reply: replies.map((e) => e.text).join('\n'), end };
}

/** A 64x64 red PNG, built by hand. */
function redPng(): Buffer {
  const { deflateSync, crc32 } = require('node:zlib') as typeof import('node:zlib');
  const chunk = (type: string, data: Buffer) => {
    const head = Buffer.alloc(4);
    head.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([head, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(64, 0);
  header.writeUInt32BE(64, 4);
  header.set([8, 2, 0, 0, 0], 8);
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(64 * 3, Buffer.from([255, 0, 0]))]);
  const pixels = deflateSync(Buffer.concat(Array.from({ length: 64 }, () => row)));
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header), chunk('IDAT', pixels), chunk('IEND', Buffer.alloc(0))]);
}

const ASK = (topic: string, options: string[]) =>
  `Use the AskUserQuestion tool now to ask me exactly one question, "${topic}", with exactly these options: ${options.join(', ')}. ` +
  `Do not do anything else first. After I answer, reply with only the option I picked.`;

describe('headless session', () => {
  let s: Session;
  beforeAll(async () => {
    s = await start(['--permission-mode', 'default']);
  }, 90_000);
  afterAll(() => stop(s));

  test('reports the session on ready and through status', async () => {
    const status = await s.z.status();
    expect(status.protocol).toBe(1);
    expect(status.mode).toBe('stdio');
    expect(status.state).toBe('idle');
    expect(status.meta.session_id).toBeTruthy();
    expect(status.meta.agent_connected).toBe(true);
    expect(status.meta.cwd).toContain('zclaude-it-');
  });

  test('streams a reply token by token and confirms it from the transcript', async () => {
    const mark = s.log.mark();
    const sent = await s.z.send('Reply with exactly this sentence and nothing else: The quick brown fox jumps over the lazy dog.');
    expect(sent.status).toBe('delivered');
    const start = await s.log.wait('stream.start', (p) => p.main, mark);
    await s.log.wait('stream.delta', (p) => p.stream === start.stream, mark);
    await s.log.wait('stream.end', (p) => p.stream === start.stream && p.status === 'done', mark);
    const entry = await s.log.wait('entry', (p) => p.role === 'assistant' && p.message_id === start.message_id, mark);
    expect(entry.text).toContain('quick brown fox');
    await s.log.wait('stream.confirmed', (p) => p.stream === start.stream, mark);
    const user = await s.log.wait('entry', (p) => p.role === 'user' && p.prompt_id === sent.prompt_id, mark);
    expect(user.origin).toBe('external');
    await s.log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received', mark);
    await s.log.wait('state', (p) => p.state === 'idle', mark);
    const deltas = s.log.since(mark, 'stream.delta').filter((e: any) => e.params.stream === start.stream);
    const text = deltas.map((e: any) => e.params.text).join('');
    expect(text).toContain('quick brown fox');

    // The turn: started by this prompt, ended after its entries, with usage.
    const end = await s.log.wait('turn.end', (p) => p.prompt_ids.includes(sent.prompt_id), mark);
    expect(end.status).toBe('done');
    expect(end.stop_reason).toBe('end_turn');
    expect(end.claude_prompt_id).toBeTruthy();
    expect(end.usage.output_tokens).toBeGreaterThan(0);
    expect(end.messages).toBe(1);
    expect(end.last_message).toContain('quick brown fox');
    const order = s.log.since(mark).map((e) => e.method);
    expect(order.lastIndexOf('entry')).toBeLessThan(order.indexOf('turn.end'));
    const activities = s.log.since(mark, 'activity').map((e: any) => e.params.activity);
    expect(activities).toContain('requesting');
    expect(activities).toContain('responding');
    expect(activities.at(-1)).toBe('idle');
    expect(s.store.view.meta.context_tokens).toBeGreaterThan(0);
    expect(s.store.view.lastTurn?.turn).toBe(end.turn);
  }, TURN * 2);

  test('attaches an image the way a file dropped on the terminal is', async () => {
    const mark = s.log.mark();
    const sent = await s.z.call('prompt.send', { text: 'What color is this image? Answer with one word.', images: [{ data: redPng().toString('base64'), media_type: 'image/png' }] });
    const end = await s.log.wait('turn.end', (p) => p.prompt_ids.includes(sent.prompt_id), mark);
    expect(end.last_message?.toLowerCase()).toContain('red');
    // Attached, not read from disk by a tool.
    expect(s.log.since(mark, 'hook').filter((e: any) => e.params.name === 'PreToolUse')).toHaveLength(0);
  }, TURN * 2);

  test('answers a question over RPC while the terminal shows the same dialog, and holds prompts meanwhile', async () => {
    const mark = s.log.mark();
    await s.z.send(ASK('Pick a fruit', ['Apple', 'Banana', 'Cherry']));
    const dialog = await s.log.wait('dialog.open', (p) => p.kind === 'question', mark);
    expect(dialog.held).toBe(true);
    expect(dialog.input.questions[0].options.map((o: any) => o.label)).toEqual(['Apple', 'Banana', 'Cherry']);
    expect((await s.z.status()).state).toBe('awaiting_input');
    await until(async () => (await s.z.screenText()).includes('Pick a fruit'), 15_000, 'the dialog on screen');

    // Typing now would answer the dialog, so the prompt waits.
    const queued = await s.z.send('After that, also say the word kiwi.');
    expect(queued.status).toBe('queued');

    const answered = await s.z.respond(dialog.id, { answers: [{ selected: ['Banana'], notes: 'ripe ones only' }] });
    expect(answered.status).toBe('answered');
    const update = await s.log.wait('dialog.update', (p) => p.id === dialog.id, mark);
    expect(update.resolved_by).toBe('rpc');
    expect(update.answers).toEqual({ 'Pick a fruit': 'Banana' });
    const result = await s.log.wait('entry', (p) => p.origin === 'tool_result' && JSON.stringify(p.blocks).includes(dialog.id), mark);
    expect(JSON.stringify(result.blocks)).toContain('ripe ones only');
    await s.log.wait('prompt', (p) => p.id === queued.prompt_id && p.status === 'delivered', mark);
    await s.log.wait('entry', (p) => p.role === 'assistant' && /banana/i.test(p.text), mark);
    await s.log.wait('prompt', (p) => p.id === queued.prompt_id && p.status === 'received', mark);
    await until(() => s.store.view.state === 'idle', TURN, 'idle');
  }, TURN * 3);

  test('lets the person at the terminal answer first', async () => {
    const mark = s.log.mark();
    await s.z.send(ASK('Pick a color', ['Red', 'Green', 'Blue']));
    const dialog = await s.log.wait('dialog.open', (p) => p.kind === 'question', mark);
    await until(async () => (await s.z.screenText()).includes('Pick a color'), 15_000, 'the dialog on screen');
    // Digit 3 picks the third option in the terminal dialog, as a person would.
    await s.z.keys([{ text: '3' }]);
    const closed = await s.log.wait('dialog.update', (p) => p.id === dialog.id && p.status !== 'open', mark);
    expect(closed.status).toBe('answered');
    expect(closed.resolved_by).toBe('terminal');
    expect(closed.answers?.['Pick a color']).toBe('Blue');
    await s.log.wait('entry', (p) => p.role === 'assistant' && /blue/i.test(p.text), mark);
    await s.log.wait('state', (p) => p.state === 'idle', mark);
  }, TURN * 2);

  test('allows and denies tool permissions', async () => {
    let mark = s.log.mark();
    await s.z.send('Use the Bash tool to run exactly this command and nothing else: touch zc-allowed.txt');
    const allow = await s.log.wait('dialog.open', (p) => p.kind === 'permission' && p.tool === 'Bash', mark);
    expect(allow.input.command).toContain('zc-allowed.txt');
    await s.z.respond(allow.id, { decision: 'allow' });
    await until(() => existsSync(join(s.dir, 'zc-allowed.txt')), 60_000, 'the allowed command to run');
    await s.log.wait('state', (p) => p.state === 'idle', mark);

    mark = s.log.mark();
    await s.z.send('Use the Bash tool to run exactly this command and nothing else: touch zc-denied.txt');
    const deny = await s.log.wait('dialog.open', (p) => p.kind === 'permission' && p.tool === 'Bash', mark);
    await s.z.respond(deny.id, { decision: 'deny', message: 'Not in this test.' });
    const result = await s.log.wait('entry', (p) => p.origin === 'tool_result' && JSON.stringify(p.blocks).includes(deny.id), mark);
    expect(JSON.stringify(result.blocks)).toContain('Not in this test.');
    await s.log.wait('state', (p) => p.state === 'idle', mark);
    expect(existsSync(join(s.dir, 'zc-denied.txt'))).toBe(false);
  }, TURN * 3);

  test('allows always: the suggestions apply and the same call runs without asking', async () => {
    let mark = s.log.mark();
    await s.z.send('Use the Bash tool to run exactly this command and nothing else: touch zc-always.txt');
    const first = await s.log.wait('dialog.open', (p) => p.kind === 'permission' && p.tool === 'Bash', mark);
    // What the card's "Yes, and always allow ..." choice applies. Claude Code decides
    // what they are (rules, directories, a mode) and where they're kept.
    expect(first.suggestions.length).toBeGreaterThan(0);
    const result = await s.z.respond(first.id, { decision: 'allow_always' });
    expect(result.status).toBe('allowed');
    await until(() => existsSync(join(s.dir, 'zc-always.txt')), 60_000, 'the command to run');
    await s.log.wait('state', (p) => p.state === 'idle', mark);

    rmSync(join(s.dir, 'zc-always.txt'));
    mark = s.log.mark();
    await s.z.send('Use the Bash tool to run exactly this command and nothing else: touch zc-always.txt');
    await until(() => existsSync(join(s.dir, 'zc-always.txt')), 60_000, 'the command to run again');
    await s.log.wait('state', (p) => p.state === 'idle', mark);
    expect(s.log.since(mark, 'dialog.open')).toHaveLength(0);
    // The suggestions can include a mode (accept edits); later tests expect default.
    if (s.store.view.meta.permission_mode !== 'default') await s.z.setMode('default');
  }, TURN * 3);

  test('reports a card that no hook describes, and answers it by choice', async () => {
    const mark = s.log.mark();
    await s.z.command('/model');
    // The model picker is drawn by the TUI alone: no hook says it is there.
    const card = await s.log.wait('dialog.open', (p) => (p.kind as string) === 'terminal', mark, 20_000);
    expect(card.input.options.length).toBeGreaterThan(1);
    expect(card.input.text).toContain('Select model');
    expect(s.store.view.state).toBe('awaiting_input');
    // Typing now would land in the card, so a prompt waits.
    const queued = await s.z.send('Reply with exactly: after-the-card');
    expect(queued.status).toBe('queued');
    const result = await s.z.respond(card.id, { decision: 'cancel' });
    expect(result.status).toBe('cancelled');
    await s.log.wait('dialog.update', (p) => p.id === card.id && p.status === 'cancelled', mark, 5_000);
    await s.log.wait('prompt', (p) => p.id === queued.prompt_id && p.status === 'received', mark);
    await s.log.wait('entry', (p) => p.role === 'assistant' && p.text.includes('after-the-card'), mark);
    await until(() => s.store.view.state === 'idle', TURN, 'idle');
  }, TURN * 2);

  test('interrupts a running turn', async () => {
    const mark = s.log.mark();
    await s.z.send('Write a detailed 800-word essay about the history of lighthouses. Do not use any tools.');
    const start = await s.log.wait('stream.start', (p) => p.main, mark);
    await s.log.wait('stream.delta', (p) => p.stream === start.stream, mark);
    const result = await s.z.interrupt();
    expect(result.sent).toBe(true);
    await s.log.wait('stream.end', (p) => p.stream === start.stream, mark);
    await until(() => s.store.view.state === 'idle', 30_000, 'idle after interrupt');
    const ended = s.log.since(mark, 'stream.end').find((e: any) => e.params.stream === start.stream) as any;
    expect(ended.params.status).toBe('aborted');
  }, TURN * 2);

  test('types keys into the terminal and reads them back from the screen', async () => {
    await s.z.keys([{ text: 'draft words here' }]);
    await until(async () => (await s.z.screenText()).includes('draft words here'), 10_000, 'typed text on screen');
    await s.z.keys(['ctrl+u']);
    await until(async () => !(await s.z.screenText()).includes('draft words here'), 10_000, 'the draft to clear');
    const screen = await s.z.screen(true);
    expect(screen.cols).toBe(120);
    expect(screen.ansi).toContain('\x1b[');
  }, 30_000);

  test('resizes the headless terminal and redraws it for a late subscriber', async () => {
    const mark = s.log.mark();
    expect(await s.z.resize(100, 30)).toBe(true);
    const resized = await s.log.wait('term.resize', () => true, mark, 5_000);
    expect(resized).toMatchObject({ cols: 100, rows: 30 });
    await until(async () => {
      const screen = await s.z.screen();
      return screen.cols === 100 && screen.rows === 30 && screen.lines.length === 30;
    }, 10_000, 'the screen to take the new size');
    expect(s.store.view.term).toEqual({ cols: 100, rows: 30 });

    // A terminal attaching now is drawn the current screen, colors and all.
    const other = await ZClaude.connect((await s.z.status()).socket);
    const log = new Log(other);
    await other.subscribe({ term: true });
    const redraw = await log.wait('term.output', (p) => !!p.redraw, 0, 5_000);
    const ansi = Buffer.from(redraw.data, 'base64').toString('utf8');
    expect(ansi).toContain('\x1b[');
    const footer = (await s.z.screen()).lines.filter((line) => line.trim()).at(-1)!.trim();
    expect(ansi.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '')).toContain(footer.slice(0, 20));
    other.detach();
    await s.z.resize(120, 40);
  }, 30_000);

  test('reads memory statistics inside Claude\'s process', async () => {
    const memory = await s.z.call('memory');
    expect(memory.pid).toBeGreaterThan(0);
    expect(memory.heap_size).toBeGreaterThan(0);
    expect(memory.usage.rss).toBeGreaterThan(0);
  }, 30_000);

  test('links a subagent to the tool call that started it and forwards its conversation', async () => {
    const mark = s.log.mark();
    await s.z.send('Use the Agent tool with subagent_type general-purpose and this task: "Reply with exactly: sub-ok". Wait for its result, then reply with exactly what it returned.');
    const call = await s.log.wait('hook', (p) => p.name === 'PreToolUse' && p.tool === 'Agent', mark);
    const started = await s.log.wait('agent.start', (p) => !p.internal, mark);
    expect(started.parent_tool_use_id).toBe(call.tool_use_id);
    expect(started.agent_type).toBe('general-purpose');
    const stopped = await s.log.wait('agent.stop', (p) => p.agent_id === started.agent_id, mark);
    expect(stopped.last_message).toContain('sub-ok');
    const own = s.log.since(mark).filter((e) => e.method === 'entry' && (e.params as any).agent_id === started.agent_id);
    expect(own.some((e: any) => e.params.role === 'assistant' && e.params.text.includes('sub-ok'))).toBe(true);
    expect(own.every((e: any) => e.params.parent_tool_use_id === call.tool_use_id && e.params.sidechain)).toBe(true);
    // Its entries come before its stop.
    const order = s.log.since(mark);
    const stopAt = order.findIndex((e) => e.method === 'agent.stop' && (e.params as any).agent_id === started.agent_id);
    expect(order.findLastIndex((e) => e.method === 'entry' && (e.params as any).agent_id === started.agent_id)).toBeLessThan(stopAt);
    await until(() => s.store.view.state === 'idle' && !s.store.view.turn, TURN, 'the turn to end');
  }, TURN * 3);

  test('lists background tasks and stops one through /tasks', async () => {
    const mark = s.log.mark();
    // `sleep` may need no permission; allow it if Claude Code asks.
    const off = s.z.on('dialog.open', (p) => {
      if (p.kind === 'permission') void s.z.respond(p.id, { decision: 'allow' }).catch(() => {});
    });
    await s.z.send('Use the Bash tool with run_in_background set to true to run exactly: sleep 417. Then reply "started" and nothing else.');
    const listed = await s.log.wait('tasks', (p) => p.tasks.some((t) => t.command?.includes('sleep 417')), mark);
    const task = listed.tasks.find((t) => t.command?.includes('sleep 417'))!;
    expect(task.status).toBe('running');
    await until(() => s.store.view.state === 'idle' && !s.store.view.turn, TURN, 'the turn to end');
    off();
    expect(await s.z.call('task.stop', { id: task.id })).toEqual({ task_id: task.id, stopped: true });
    await s.log.wait('tasks', (p) => !p.tasks.some((t) => t.id === task.id), mark, 5_000);
    await until(() => Bun.spawnSync(['pgrep', '-f', '^sleep 417']).exitCode !== 0, 10_000, 'the shell to be killed');
    await until(async () => (await s.z.screen()).permission_mode !== undefined, 10_000, 'the tasks view to close');
  }, TURN * 2);

  test('sets the effort level', async () => {
    const before = (await s.z.status()).meta.effort;
    expect(before).toBeTruthy();
    const level = before === 'low' ? 'medium' : 'low';
    expect(await s.z.call('effort.set', { level })).toEqual({ effort: level, status: 'switching' });
    await until(() => s.store.view.meta.effort === level, 10_000, 'meta to follow');
    await s.z.call('effort.set', { level: before as any });
    await until(() => s.store.view.meta.effort === before, 10_000, 'meta to follow back');
  }, 30_000);

  test('cycles the permission mode with Shift+Tab', async () => {
    const result = await s.z.setMode('acceptEdits');
    expect(result.mode).toBe('acceptEdits');
    await until(() => s.store.view.meta.permission_mode === 'acceptEdits', 5_000, 'meta to follow');
    expect((await s.z.screen()).permission_mode).toBe('acceptEdits');
    expect((await s.z.setMode('default')).mode).toBe('default');
  }, 60_000);

  test('switches the model through /model', async () => {
    const mark = s.log.mark();
    const result = await s.z.setModel(MODEL);
    expect(result.status).toBe('switching');
    await s.log.wait('meta', (p) => p.model_pending === '' && 'model_pending' in p, mark, 30_000);
    expect(s.store.view.meta.model_error).toBe('');
    expect(s.store.view.meta.model?.toLowerCase()).toContain('haiku');
  }, 60_000);

  test('delivers a prompt through the rewake hook', async () => {
    const mark = s.log.mark();
    const sent = await s.z.send('Reply with exactly: hook-delivered', 'hook');
    await s.log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'delivered', mark, 30_000);
    await s.log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received', mark);
    await s.log.wait('entry', (p) => p.role === 'assistant' && p.text.includes('hook-delivered'), mark);
    await until(() => s.store.view.state === 'idle', TURN, 'idle');
  }, TURN * 2);

  test('lets a second consumer attach over the socket with history and a terminal redraw', async () => {
    const status = await s.z.status();
    const other = await ZClaude.connect(status.socket);
    const log = new Log(other);
    const snapshot = await other.subscribe({ history: true, term: true });
    expect(snapshot.meta.session_id).toBe(status.meta.session_id);
    await log.wait('entry', (p) => !!p.historic && p.role === 'assistant' && p.text.includes('quick brown fox'), 0, 10_000);
    await log.wait('term.output', (p) => !!p.redraw, 0, 10_000);
    const reply = turn(s, 'Reply with exactly: seen-by-both');
    await log.wait('entry', (p) => p.role === 'assistant' && p.text.includes('seen-by-both'), 0);
    await log.wait('term.output', (p) => !p.redraw, 0, 10_000);
    expect((await reply).reply).toContain('seen-by-both');
    // Detaching leaves the session running.
    other.detach();
    expect(await other.exited).toBeNull();
    expect((await s.z.status()).state).toBe('idle');
  }, TURN * 2);

  test('runs slash commands: /clear starts a new conversation', async () => {
    const before = (await s.z.status()).meta.session_id;
    const mark = s.log.mark();
    const sent = await s.z.command('/clear');
    await s.log.wait('hook', (p) => p.name === 'SessionStart' && p.source === 'clear', mark, 30_000);
    await s.log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received', mark, 30_000);
    await until(async () => (await s.z.status()).meta.session_id !== before, 10_000, 'a new session id');
  }, 60_000);

  test('shuts down gracefully: /exit, SessionEnd, exit code 0', async () => {
    const mark = s.log.mark();
    const socket = (await s.z.status()).socket;
    expect(existsSync(socket)).toBe(true);
    const code = await s.z.shutdown();
    expect(code).toBe(0);
    await s.log.wait('hook', (p) => p.name === 'SessionEnd', mark, 1_000);
    const exit = await s.log.wait('exit', () => true, mark, 1_000);
    expect(exit).toMatchObject({ code: 0 });
    expect(exit.signal).toBeUndefined();
    expect(existsSync(socket)).toBe(false);
  }, 30_000);
});

describe('plan mode', () => {
  let s: Session;
  beforeAll(async () => {
    s = await start(['--permission-mode', 'plan']);
  }, 90_000);
  afterAll(() => stop(s));

  test('takes feedback on a plan, then approves the revision into accept-edits', async () => {
    const mark = s.log.mark();
    await s.z.send(
      'Plan this task: create a file named plan-draft.txt containing the word ok. The plan is a single step; do not explore or ask questions. ' +
        'Present it with ExitPlanMode right away, then after approval create the file with the Write tool.',
    );
    const first = await s.log.wait('dialog.open', (p) => p.kind === 'plan', mark);
    expect(first.tool).toBe('ExitPlanMode');
    expect(first.input.plan).toContain('plan-draft.txt');
    // The card's choices, read off the terminal: what Enter, or a person, would pick from.
    const offered = await s.log.wait('dialog.update', (p) => p.id === first.id && !!p.modes?.length, mark, 15_000);
    expect(offered.modes).toContain('default');
    await until(async () => (await s.z.screenText()).includes('Tell Claude what to change'), 15_000, 'the plan card');

    // "Tell Claude what to change": Claude stays in plan mode and revises.
    const rejected = await s.z.respond(first.id, { decision: 'reject', message: 'Name the file plan-done.txt instead.' });
    expect(rejected.status).toBe('rejected');
    const second = await s.log.wait('dialog.open', (p) => p.kind === 'plan' && p.id !== first.id, mark);
    expect(second.input.plan).toContain('plan-done.txt');
    expect(s.store.view.meta.permission_mode).toBe('plan');

    const approved = await s.z.respond(second.id, { decision: 'approve', mode: 'acceptEdits' });
    expect(approved).toMatchObject({ status: 'approved', mode: 'acceptEdits' });
    await s.log.wait('dialog.update', (p) => p.id === second.id && p.status === 'approved', mark);
    await until(() => existsSync(join(s.dir, 'plan-done.txt')), TURN, 'the planned file');
    expect(existsSync(join(s.dir, 'plan-draft.txt'))).toBe(false);
    await until(() => s.store.view.meta.permission_mode === 'acceptEdits', 30_000, 'accept-edits mode');
    await s.log.wait('state', (p) => p.state === 'idle', mark);
  }, TURN * 4);
});

describe('MCP elicitation', () => {
  let s: Session;
  beforeAll(async () => {
    const config = { mcpServers: { elicit: { command: process.execPath, args: [join(FIXTURES, 'elicit-server.ts')] } } };
    s = await start(['--permission-mode', 'default', '--strict-mcp-config', '--mcp-config', JSON.stringify(config), '--allowedTools', 'mcp__elicit__ask_name']);
  }, 90_000);
  afterAll(() => stop(s));

  test('answers a server\'s elicitation over RPC', async () => {
    const mark = s.log.mark();
    await s.z.send('Call the ask_name tool of the elicit MCP server now, then reply with exactly what it returned and nothing else.');
    const dialog = await s.log.wait('dialog.open', (p) => p.kind === 'elicitation', mark);
    expect(dialog.held).toBe(true);
    expect(dialog.input.server).toBe('elicit');
    expect(dialog.input.message).toBe('What is your name?');
    expect(dialog.input.requested_schema.properties.name.type).toBe('string');
    const result = await s.z.respond(dialog.id, { action: 'accept', content: { name: 'Ada' } });
    expect(result.status).toBe('accepted');
    await s.log.wait('entry', (p) => p.origin === 'tool_result' && JSON.stringify(p.blocks).includes('name=Ada'), mark);
    await s.log.wait('state', (p) => p.state === 'idle', mark);
  }, TURN * 2);
});

describe('API retries', () => {
  test('reports Claude Code retrying an overloaded API, and the turn ending when interrupted', async () => {
    const api = Bun.spawn([process.execPath, join(FIXTURES, 'overloaded-api.ts'), '0'], { stdout: 'pipe' });
    const reader = api.stdout.getReader();
    const port = Number(new TextDecoder().decode((await reader.read()).value).match(/listening (\d+)/)![1]);
    const dir = mkdtempSync(join(tmpdir(), 'zclaude-it-'));
    const z = ZClaude.spawn({ bin: BIN, cwd: dir, args: ['--model', MODEL], env: { ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}` } });
    const log = new Log(z);
    try {
      await z.ready;
      await log.wait('state', (p) => p.state === 'idle', 0, 60_000);
      const sent = await z.send('Reply with exactly: hello');
      const retry = await log.wait('api.retry', (p) => p.status === 529, 0, 60_000);
      expect(retry.error).toBe('Overloaded');
      expect(retry.attempt).toBeGreaterThan(0);
      expect(retry.max_attempts).toBeGreaterThanOrEqual(retry.attempt!);
      const retrying = await log.wait('activity', (p) => p.activity === 'retrying', 0, 5_000);
      expect(retrying.retry_at).toBeGreaterThan(Date.now() - 1_000);
      expect((await z.interrupt()).sent).toBe(true);
      const end = await log.wait('turn.end', () => true, 0, 10_000);
      expect(end).toMatchObject({ status: 'interrupted', messages: 0 });
      expect(end.prompt_ids).toContain(sent.prompt_id);
    } finally {
      await z.shutdown();
      api.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 90_000);
});

describe('interactive session', () => {
  test('wraps a real terminal: socket and ctl control, terminal output, /exit typed at the terminal', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zclaude-it-'));
    const socket = join(dir, 'session.sock');
    // The PTY host stands in for a person's terminal emulator.
    const child = spawn('python3', ['-I', join(FIXTURES, 'pty_host.py'), BIN, '--socket', socket, '--model', MODEL], {
      cwd: dir,
      stdio: ['pipe', 'pipe', 'inherit'],
      env: { ...process.env, TERM: 'xterm-256color', PTY_COLS: '120', PTY_ROWS: '40' },
    });
    let output = '';
    child.stdout!.on('data', (chunk) => (output += chunk.toString()));
    const exited = new Promise<number>((resolve) => child.on('exit', (code, signal) => resolve(code ?? (signal ? 128 : 1))));
    try {
      await until(() => existsSync(socket), 15_000, 'the socket');
      const z = await ZClaude.connect(socket);
      const log = new Log(z);
      const snapshot = await z.subscribe();
      expect(snapshot.mode).toBe('interactive');
      expect(snapshot.term).toEqual({ cols: 120, rows: 40 });
      if (snapshot.state !== 'idle') await log.wait('state', (p) => p.state === 'idle', 0, 60_000);
      const sent = await z.send('Reply with exactly: from-the-socket');
      await log.wait('entry', (p) => p.role === 'assistant' && p.text.includes('from-the-socket'));
      await log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received');
      // The person's terminal shows the same conversation.
      await until(() => output.includes('from-the-socket'), 10_000, 'terminal output');

      const ctl = Bun.spawnSync([BIN, 'ctl', '--socket', socket, 'status']);
      expect(ctl.exitCode).toBe(0);
      expect(JSON.parse(ctl.stdout.toString()).mode).toBe('interactive');
      const screen = Bun.spawnSync([BIN, 'ctl', '--socket', socket, 'screen']);
      expect(screen.stdout.toString()).toContain('from-the-socket');
      // The real terminal owns the size of an interactive session.
      await expect(z.resize(80, 24)).rejects.toThrow('real terminal');

      // Keys typed at the real terminal: a prompt, then /exit.
      await until(() => s_idle(z), 30_000, 'idle');
      const mark = log.mark();
      child.stdin!.write('Reply with exactly: typed-at-the-terminal');
      await Bun.sleep(300);
      child.stdin!.write('\r');
      const typed = await log.wait('entry', (p) => p.role === 'user' && p.text.includes('typed-at-the-terminal'), mark);
      expect(typed.origin).toBe('terminal');
      await log.wait('entry', (p) => p.role === 'assistant' && p.text.includes('typed-at-the-terminal'), mark);
      await until(() => s_idle(z), 30_000, 'idle');
      child.stdin!.write('/exit');
      await Bun.sleep(300);
      child.stdin!.write('\r');
      const exit = await log.wait('exit', () => true, mark, 30_000);
      expect(exit).toMatchObject({ code: 0 });
      expect(await exited).toBe(0);
      expect(existsSync(socket)).toBe(false);
    } finally {
      child.kill('SIGKILL');
      rmSync(dir, { recursive: true, force: true });
    }
  }, TURN * 3);
});

async function s_idle(z: ZClaude): Promise<boolean> {
  try {
    return (await z.status()).state === 'idle';
  } catch {
    return false;
  }
}
