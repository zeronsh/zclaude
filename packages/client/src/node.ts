// Node/Bun transports: spawn a headless session, or attach to a running one.
import { spawn, type ChildProcess } from 'node:child_process';
import { readdirSync, statSync } from 'node:fs';
import { connect as netConnect, type Socket } from 'node:net';
import { homedir } from 'node:os';
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
  /** Resolves with the exit code once the session is gone. */
  exited: Promise<number>;
  child?: ChildProcess;
  #socket?: Socket;

  private constructor(write: (line: string) => void) {
    super(write);
    this.ready = Promise.resolve(undefined as unknown as Snapshot);
    this.exited = Promise.resolve(0);
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
    const session = new ZClaude((line) => child.stdin!.write(`${line}\n`));
    session.child = child;
    child.stdout!.setEncoding('utf8');
    child.stdout!.on('data', (chunk: string) => session.feed(chunk));
    session.ready = session.waitFor('ready', () => true, 60_000).then((params) => params.snapshot);
    session.exited = new Promise((resolve) => {
      child.on('exit', (code, signal) => {
        session.close('zclaude exited');
        resolve(code ?? (signal ? 128 : 1));
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
    const session = new ZClaude((line) => socket.write(`${line}\n`));
    session.#socket = socket;
    socket.setEncoding('utf8');
    socket.on('data', (chunk: string) => session.feed(chunk));
    session.exited = new Promise((resolve) => socket.on('close', () => {
      session.close('socket closed');
      resolve(0);
    }));
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

  /** Ends the session (headless) or detaches (socket). */
  async shutdown(): Promise<number> {
    if (this.#socket) {
      this.#socket.end();
      return this.exited;
    }
    await this.call('shutdown').catch(() => {});
    const timer = setTimeout(() => this.child?.kill('SIGKILL'), 10_000);
    const code = await this.exited;
    clearTimeout(timer);
    return code;
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
  return names
    .map((name) => join(dir, name))
    .map((path) => ({ path, time: statSync(path).mtimeMs }))
    .sort((a, b) => b.time - a.time)
    .map((item) => item.path);
}
