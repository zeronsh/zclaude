// Node/Bun transports: spawn a headless session, or attach to a running one.
import { spawn, type ChildProcess } from 'node:child_process';
import { readdirSync, statSync } from 'node:fs';
import { connect as netConnect, type Socket } from 'node:net';
import { constants as osConstants, homedir } from 'node:os';
import { join } from 'node:path';
import { Peer } from './peer.ts';
import type { DialogResponse, Key, PermissionMode, Snapshot } from './protocol.ts';

export interface SpawnOptions {
  /** Path to the zclaude binary. Defaults to $ZCLAUDE_BIN, then `zclaude` on PATH. */
  bin?: string;
  cwd?: string;
  /** Arguments passed on to `claude`, e.g. ['--model', 'haiku']. */
  args?: string[];
  cols?: number;
  rows?: number;
  env?: Record<string, string | undefined>;
  /** Also open the control socket so `zclaude ctl` can attach. Default true. */
  socket?: boolean;
  /** Write zclaude's debug log here. */
  log?: string;
}

/** A session: the RPC peer plus convenience methods. */
export class ZClaude extends Peer {
  /** The snapshot from `ready` (spawned) or from the first `status` (attached). */
  ready: Promise<Snapshot>;
  /**
   * Resolves when this connection ends: with Claude's exit code (128 + n for signal
   * n) if the session ended, or null if this consumer detached or lost the socket.
   */
  exited: Promise<number | null>;
  /** The `exit` event's signal name, once the session has ended by a signal. */
  exitSignal?: string;
  child?: ChildProcess;
  #socket?: Socket;
  #exitCode: number | null = null;

  private constructor(write: (line: string) => void) {
    super(write);
    this.ready = Promise.resolve(undefined as unknown as Snapshot);
    this.exited = Promise.resolve(null);
    this.on('exit', (params) => {
      this.#exitCode = params.code;
      this.exitSignal = params.signal;
    });
  }

  /** Starts `zclaude --stdio`: Claude Code runs headless and this process owns it. */
  static spawn(options: SpawnOptions = {}): ZClaude {
    const bin = options.bin ?? process.env.ZCLAUDE_BIN ?? 'zclaude';
    const args = ['--stdio', '--size', `${options.cols ?? 120}x${options.rows ?? 40}`];
    if (options.socket === false) args.push('--no-socket');
    if (options.log) args.push('--log', options.log);
    args.push(...(options.args ?? []));
    const child = spawn(bin, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    const session = new ZClaude((line) => {
      if (child.stdin!.writable) child.stdin!.write(`${line}\n`);
    });
    session.child = child;
    child.stdin!.on('error', () => {}); // zclaude went away; `exited` reports it.
    child.once('spawn', () => session.markOpen());
    child.stdout!.setEncoding('utf8');
    child.stdout!.on('data', (chunk: string) => session.feed(chunk));
    session.ready = session.waitFor('ready', () => true, 60_000).then((params) => params.snapshot);
    session.exited = new Promise((resolve) => {
      child.on('exit', (code, signal) => {
        session.close('zclaude exited');
        // zclaude exits with Claude's code; a signal here means zclaude itself was killed.
        resolve(code ?? 128 + (signal ? (osConstants.signals as Record<string, number>)[signal] ?? 0 : 0));
      });
      child.on('error', (error) => {
        session.close(String(error));
        resolve(127);
      });
    });
    return session;
  }

  /** Attaches to a running session's control socket (interactive or headless). */
  static async connect(socketPath?: string): Promise<ZClaude> {
    const path = socketPath ?? liveSockets()[0];
    if (!path) throw new Error('no zclaude session is running');
    const socket = netConnect(path);
    await new Promise<void>((resolve, reject) => {
      socket.once('connect', resolve);
      socket.once('error', reject);
    });
    const session = new ZClaude((line) => {
      if (!socket.destroyed) socket.write(`${line}\n`);
    });
    session.#socket = socket;
    socket.setEncoding('utf8');
    socket.on('data', (chunk: string) => session.feed(chunk));
    socket.on('error', () => {}); // `close` follows, and `exited` reports it.
    session.exited = new Promise((resolve) =>
      socket.on('close', () => {
        session.close('socket closed');
        resolve(session.#exitCode);
      }),
    );
    session.markOpen();
    session.ready = session.call('status');
    return session;
  }

  subscribe(options: { term?: boolean; history?: boolean } = {}): Promise<Snapshot> {
    return this.call('subscribe', options);
  }

  status(): Promise<Snapshot> {
    return this.call('status');
  }

  send(text: string, transport: 'inproc' | 'hook' = 'inproc') {
    return this.call('prompt.send', { text, transport });
  }

  command(text: string) {
    return this.call('command', { text });
  }

  interrupt() {
    return this.call('interrupt');
  }

  respond(id: string, response: DialogResponse) {
    return this.call('dialog.respond', { id, ...response });
  }

  setModel(model: string) {
    return this.call('model.set', { model });
  }

  setMode(mode: PermissionMode) {
    return this.call('mode.set', { mode });
  }

  keys(keys: Array<Key | { text: string }>, delayMs?: number) {
    return this.call('keys', { keys, delay_ms: delayMs });
  }

  screen(ansi = false) {
    return this.call('screen', { ansi });
  }

  async screenText(): Promise<string> {
    return (await this.screen()).lines.join('\n');
  }

  resize(cols: number, rows: number) {
    return this.call('term.resize', { cols, rows });
  }

  /** Writes raw bytes to the terminal, exactly as typing would. */
  write(data: string | Uint8Array) {
    const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
    return this.call('term.write', { data: Buffer.from(bytes).toString('base64') });
  }

  /**
   * Ends the session the way a person would (the turn stops, open dialogs are
   * refused, /exit is typed) and resolves with Claude's exit code. zclaude falls
   * back to SIGHUP and then SIGKILL; `force` starts at SIGHUP.
   */
  async shutdown(options: { force?: boolean } = {}): Promise<number | null> {
    if (this.closed) return this.exited;
    await this.call('shutdown', { force: options.force }).catch(() => {});
    // zclaude escalates by itself. This only covers a zclaude that is itself stuck.
    const timer = setTimeout(() => this.child?.kill('SIGKILL'), 20_000);
    const code = await this.exited;
    clearTimeout(timer);
    return code;
  }

  /**
   * Closes this connection. Over a socket the session carries on. A spawned session
   * loses its owner, so zclaude shuts it down as `shutdown()` would.
   */
  detach(): void {
    if (this.#socket) this.#socket.end();
    else this.child?.stdin?.end();
  }
}

/** Sockets of running sessions, newest first. */
export function liveSockets(): string[] {
  const dir = join(homedir(), '.zclaude', 'run');
  let names: string[] = [];
  try {
    names = readdirSync(dir).filter((name) => name.endsWith('.sock'));
  } catch {
    return [];
  }
  const found: Array<{ path: string; time: number }> = [];
  for (const name of names) {
    const path = join(dir, name);
    try {
      found.push({ path, time: statSync(path).mtimeMs });
    } catch {} // removed as its session ended
  }
  return found.sort((a, b) => b.time - a.time).map((item) => item.path);
}
