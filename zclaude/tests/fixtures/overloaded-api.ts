// A stand-in for the Anthropic API that is always overloaded: every
// /v1/messages call gets 529, so Claude Code retries. Everything else is 404.
//
//   bun overloaded-api.ts PORT      prints "listening" once it is up
const port = Number(process.argv[2] ?? 0);
const server = Bun.serve({
  port,
  hostname: '127.0.0.1',
  fetch(request) {
    if (new URL(request.url).pathname === '/v1/messages') {
      return Response.json({ type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } }, { status: 529, headers: { 'x-should-retry': 'true' } });
    }
    return Response.json({}, { status: 404 });
  },
});
console.log(`listening ${server.port}`);
