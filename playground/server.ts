// The playground server: one headless zclaude session, shown in a browser.
//
//   bun server.ts [--port 7777] [--bin PATH] [--cwd DIR] [-- claude args...]
//
// This is a consumer of zclaude, nothing more. zclaude stores nothing, so the
// storage here is this server's own choice: an in-memory log of every event except
// terminal output, replayed to each browser that connects so a reload rebuilds the
// whole conversation. The terminal is redrawn from zclaude's screen instead.
//
// It hands out a shell-equivalent terminal, so it binds to loopback and every route
// needs the random token in the printed URL (or the cookie set from it).
import { ZClaude, type ZEvent } from '@zclaude/client';
import type { ServerWebSocket } from 'bun';
import { existsSync, statSync } from 'node:fs';
import { dirname, join, normalize, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';

const root = dirname(new URL(import.meta.url).pathname);
const dist = join(root, 'dist');

// ---------- Arguments ----------

const argv = process.argv.slice(2);
let port = 7777;
let bin = '';
let cwd = process.cwd();
let claudeArgs: string[] = [];
for (let i = 0; i < argv.length; i++) {
  const arg = argv[i]!;
  if (arg === '--') {
    claudeArgs = argv.slice(i + 1);
    break;
  } else if (arg === '--port') port = Number(argv[++i]);
  else if (arg === '--bin') bin = resolve(argv[++i]!);
  else if (arg === '--cwd') cwd = resolve(argv[++i]!);
  else {
    console.error(`unknown flag ${arg}\nusage: bun server.ts [--port 7777] [--bin PATH] [--cwd DIR] [-- claude args...]`);
    process.exit(2);
  }
}
if (!bin) {
  const local = resolve(root, '../zclaude/bin/zclaude');
  bin = existsSync(local) ? local : (process.env.ZCLAUDE_BIN ?? 'zclaude');
}

const token = randomBytes(16).toString('hex');

// Public methods a browser may call. Everything else stays between zclaude and us.
const ALLOWED = new Set([
  'prompt.send',
  'command',
  'interrupt',
  'dialog.respond',
  'model.set',
  'mode.set',
  'keys',
  'term.write',
  'term.resize',
  'screen',
  'status',
  'memory',
]);

// xterm.js answers terminal queries (device attributes, cursor reports, focus) by
// itself. Claude asked the PTY, not this browser, so those replies are dropped.
const TERMINAL_REPLY = /^\x1b\[(\?[\d;]*c|>[\d;]*c|\d+;\d+R|I|O|\?[\d;]*\$y|>[\d;]*\|?[^\x1b]*)$/;

// ---------- Session ----------

type Socket = ServerWebSocket<{ term: boolean }>;
const sockets = new Set<Socket>();
let session: ZClaude | null = null;
/** Every event but terminal output since the session started. */
let log: ZEvent[] = [];
let exitCode: number | null = null;

function broadcast(message: unknown, onlyTerm = false): void {
  const text = JSON.stringify(message);
  for (const socket of sockets) {
    if (onlyTerm && !socket.data.term) continue;
    socket.send(text);
  }
}

function start(): void {
  log = [];
  exitCode = null;
  const z = ZClaude.spawn({ bin, cwd, args: claudeArgs });
  session = z;
  z.onEvent((event) => {
    if (event.method === 'term.output') {
      broadcast({ type: 'term', data: event.params.data }, true);
      return;
    }
    log.push(event);
    broadcast({ type: 'event', event });
  });
  z.ready
    .then(() => z.subscribe({ term: true }))
    .catch((error) => console.error('zclaude did not start:', error.message));
  z.exited.then((code) => {
    if (session !== z) return;
    exitCode = code;
    console.log(`zclaude exited with code ${code}`);
    broadcast({ type: 'exited', code });
    broadcast({ type: 'term', data: Buffer.from(`\r\n[zclaude exited with code ${code}]\r\n`).toString('base64') }, true);
  });
}

async function call(method: string, params: unknown): Promise<unknown> {
  if (!session || session.closed) throw new Error('zclaude is not running');
  if (method === 'term.write') {
    const data = (params as any)?.data;
    if (typeof data === 'string' && TERMINAL_REPLY.test(Buffer.from(data, 'base64').toString('latin1'))) return true;
  }
  return session.call(method, params);
}

// ---------- HTTP ----------

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
};

function authorized(request: Request, url: URL): boolean {
  if (url.searchParams.get('t') === token) return true;
  const cookie = request.headers.get('cookie') ?? '';
  return cookie.split(/;\s*/).includes(`zclaude_playground=${token}`);
}

function serveFile(pathname: string, setCookie: boolean): Response {
  if (!existsSync(join(dist, 'index.html'))) {
    return new Response('The frontend is not built. Run `bun run build` in playground/.', { status: 503 });
  }
  const relative = pathname === '/' ? 'index.html' : normalize(pathname).replace(/^\/+/, '');
  const file = join(dist, relative);
  if (!file.startsWith(dist) || !existsSync(file) || !statSync(file).isFile()) return new Response('not found', { status: 404 });
  const headers: Record<string, string> = {
    'content-type': MIME[file.slice(file.lastIndexOf('.'))] ?? 'application/octet-stream',
    'cache-control': 'no-store',
  };
  // Lets the page's own assets and socket through without the token in every URL.
  if (setCookie) headers['set-cookie'] = `zclaude_playground=${token}; HttpOnly; SameSite=Strict; Path=/`;
  return new Response(Bun.file(file), { headers });
}

const server = Bun.serve<{ term: boolean }>({
  hostname: '127.0.0.1',
  port,
  async fetch(request, srv) {
    const url = new URL(request.url);
    if (!authorized(request, url)) return new Response('forbidden', { status: 403 });
    if (url.pathname === '/ws') {
      if (srv.upgrade(request, { data: { term: false } })) return undefined;
      return new Response('expected a WebSocket', { status: 400 });
    }
    return serveFile(url.pathname, url.pathname === '/');
  },
  websocket: {
    maxPayloadLength: 64 * 1024 * 1024,
    open(socket) {
      sockets.add(socket);
      socket.send(JSON.stringify({ type: 'replay', events: log, exited: exitCode }));
      // The terminal starts from the current screen, then follows live output.
      const z = session;
      if (!z || z.closed) {
        socket.data.term = true;
        return;
      }
      z.screen(true)
        .then((screen) => {
          socket.send(JSON.stringify({ type: 'term', data: Buffer.from(screen.ansi ?? '').toString('base64'), redraw: true }));
        })
        .catch(() => {})
        .finally(() => {
          socket.data.term = true;
        });
    },
    async message(socket, raw) {
      let message: any;
      try {
        message = JSON.parse(String(raw));
      } catch {
        return;
      }
      const { id, method, params } = message ?? {};
      if (method === 'playground.restart') {
        if (session && !session.closed) await session.shutdown();
        start();
        broadcast({ type: 'restarted' });
        socket.send(JSON.stringify({ type: 'reply', id, result: true }));
        return;
      }
      if (!ALLOWED.has(method)) {
        socket.send(JSON.stringify({ type: 'reply', id, error: `method ${method} is not available here` }));
        return;
      }
      try {
        const result = await call(method, params);
        socket.send(JSON.stringify({ type: 'reply', id, result }));
      } catch (error) {
        socket.send(JSON.stringify({ type: 'reply', id, error: (error as Error).message }));
      }
    },
    close(socket) {
      sockets.delete(socket);
    },
  },
});

start();
console.log(`zclaude playground: http://127.0.0.1:${server.port}/?t=${token}`);
console.log(`zclaude: ${bin}${claudeArgs.length ? ` -- ${claudeArgs.join(' ')}` : ''} (cwd ${cwd})`);

async function stop(): Promise<void> {
  if (session && !session.closed) await session.shutdown().catch(() => {});
  server.stop(true);
  process.exit(0);
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
