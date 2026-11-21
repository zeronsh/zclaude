// Drives real Claude Code sessions on Haiku through zclaude's public protocol, the
// way any consumer would. Needs a logged-in `claude` on PATH and a built binary
// (`make` in zclaude/). Run from the repo root: `bun test --timeout 240000 zclaude/tests`.
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { ZClaude, SessionStore, type EventMap, type EventType, type ZEvent } from '../../packages/client/src/index.ts';

const BIN = process.env.ZCLAUDE_BIN ?? resolve(import.meta.dir, '../bin/zclaude');
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

async function start(args: string[]): Promise<Session> {
  const dir = mkdtempSync(join(tmpdir(), 'zclaude-it-'));
  const z = ZClaude.spawn({ bin: BIN, cwd: dir, args: ['--model', MODEL, ...args], cols: 120, rows: 40 });
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

/** Sends a prompt and waits for the turn it starts to finish. */
async function turn(s: Session, text: string): Promise<{ mark: number; reply: string }> {
  const mark = s.log.mark();
  const sent = await s.z.send(text);
  await s.log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received', mark);
  await s.log.wait('state', (p) => p.state === 'idle', mark);
  const replies = s.log.since(mark, 'entry').map((e) => e.params as EventMap['entry']).filter((e) => e.role === 'assistant');
  return { mark, reply: replies.map((e) => e.text).join('\n') };
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
  }, TURN);

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

    const answered = await s.z.respond(dialog.id, { answers: [{ selected: ['Banana'] }] });
    expect(answered.status).toBe('answered');
    const update = await s.log.wait('dialog.update', (p) => p.id === dialog.id, mark);
    expect(update.resolved_by).toBe('rpc');
    expect(update.answers).toEqual({ 'Pick a fruit': 'Banana' });
    await s.log.wait('prompt', (p) => p.id === queued.prompt_id && p.status === 'delivered', mark);
    await s.log.wait('entry', (p) => p.role === 'assistant' && /banana/i.test(p.text), mark);
    await s.log.wait('prompt', (p) => p.id === queued.prompt_id && p.status === 'received', mark);
    await until(() => s.store.view.state === 'idle', TURN, 'idle');
  }, TURN * 2);

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
  }, TURN);

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
  }, TURN);

  test('types keys into the terminal and reads them back from the screen', async () => {
    await s.z.keys([{ text: 'draft words here' }]);
    await until(async () => (await s.z.screenText()).includes('draft words here'), 10_000, 'typed text on screen');
    await s.z.keys(['ctrl+u']);
    await until(async () => !(await s.z.screenText()).includes('draft words here'), 10_000, 'the draft to clear');
    const screen = await s.z.screen(true);
    expect(screen.cols).toBe(120);
    expect(screen.ansi).toContain('\x1b[');
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
  }, TURN);

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
    await other.shutdown();
  }, TURN);

  test('runs slash commands: /clear starts a new conversation', async () => {
    const before = (await s.z.status()).meta.session_id;
    const mark = s.log.mark();
    const sent = await s.z.command('/clear');
    await s.log.wait('hook', (p) => p.name === 'SessionStart' && p.source === 'clear', mark, 30_000);
    await s.log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received', mark, 30_000);
    await until(async () => (await s.z.status()).meta.session_id !== before, 10_000, 'a new session id');
  }, 60_000);
});

describe('plan mode', () => {
  let s: Session;
  beforeAll(async () => {
    s = await start(['--permission-mode', 'plan']);
  }, 90_000);
  afterAll(() => stop(s));

  test('approves a plan and switches to accept-edits', async () => {
    const mark = s.log.mark();
    await s.z.send(
      'Plan this task: create a file named plan-done.txt containing the word ok. The plan is a single step; do not explore or ask questions. ' +
        'Present it with ExitPlanMode right away, then after approval create the file with the Write tool.',
    );
    const plan = await s.log.wait('dialog.open', (p) => p.kind === 'plan', mark);
    expect(plan.tool).toBe('ExitPlanMode');
    await s.z.respond(plan.id, { decision: 'approve', mode: 'acceptEdits' });
    await s.log.wait('dialog.update', (p) => p.id === plan.id && p.status === 'approved', mark);
    await until(() => existsSync(join(s.dir, 'plan-done.txt')), TURN, 'the planned file');
    await until(() => s.store.view.meta.permission_mode === 'acceptEdits', 30_000, 'accept-edits mode');
  }, TURN * 2);
});

describe.if(process.platform === 'darwin')('interactive session', () => {
  test('wraps the real terminal and takes commands over the socket and ctl', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zclaude-it-'));
    const socket = join(dir, 'session.sock');
    // `script` gives zclaude a real terminal, as a person's shell would.
    const child = spawn('script', ['-q', '/dev/null', BIN, '--socket', socket, '--model', MODEL], {
      cwd: dir,
      stdio: ['pipe', 'pipe', 'inherit'],
      env: { ...process.env, TERM: 'xterm-256color' },
    });
    let output = '';
    child.stdout!.on('data', (chunk) => (output += chunk.toString()));
    try {
      await until(() => existsSync(socket), 15_000, 'the socket');
      const z = await ZClaude.connect(socket);
      const log = new Log(z);
      const snapshot = await z.subscribe();
      expect(snapshot.mode).toBe('interactive');
      if (snapshot.state !== 'idle') await log.wait('state', (p) => p.state === 'idle', 0, 60_000);
      const sent = await z.send('Reply with exactly: from-the-socket');
      await log.wait('entry', (p) => p.role === 'assistant' && p.text.includes('from-the-socket'));
      await log.wait('prompt', (p) => p.id === sent.prompt_id && p.status === 'received');
      // The terminal shows the same conversation.
      await until(() => output.includes('from-the-socket'), 10_000, 'terminal output');

      const ctl = Bun.spawnSync([BIN, 'ctl', '--socket', socket, 'status']);
      expect(JSON.parse(ctl.stdout.toString()).mode).toBe('interactive');
      const screen = Bun.spawnSync([BIN, 'ctl', '--socket', socket, 'screen']);
      expect(screen.stdout.toString()).toContain('from-the-socket');

      // Keys typed at the real terminal: /exit ends the session.
      await until(() => s_idle(z), 30_000, 'idle');
      child.stdin!.write('/exit');
      await Bun.sleep(300);
      child.stdin!.write('\r');
      const code = await new Promise<number>((resolve) => child.on('exit', (c) => resolve(c ?? 1)));
      expect(code).toBe(0);
      expect(existsSync(socket)).toBe(false);
    } finally {
      child.kill('SIGKILL');
      rmSync(dir, { recursive: true, force: true });
    }
  }, TURN * 2);
});

async function s_idle(z: ZClaude): Promise<boolean> {
  try {
    return (await z.status()).state === 'idle';
  } catch {
    return false;
  }
}
