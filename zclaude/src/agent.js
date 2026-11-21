// Loaded inside Claude Code's own process through BUN_OPTIONS=--preload (native
// Bun builds) or NODE_OPTIONS=--require (npm/Node installs), before the app starts.
// Talks to the owning zclaude over its Unix socket, one JSON object per line.
//
// Sends: model stream events, tapped from response readers. Of each request, only
// its conversation link and one-way fingerprints of its tool names and system prompt.
// Never headers or messages, so credentials and prompts in flight stay in this process.
// Receives: input to feed into the TUI, and memory-stat requests.
'use strict';
(() => {
  const socketPath = process.env.ZCLAUDE_AGENT_SOCKET;
  const hasBunOrig = Object.prototype.hasOwnProperty.call(process.env, 'ZCLAUDE_ORIGINAL_BUN_OPTIONS');
  const originalBunOptions = process.env.ZCLAUDE_ORIGINAL_BUN_OPTIONS;
  const preloadBunOptions = hasBunOrig ? process.env.BUN_OPTIONS : undefined;
  const hasNodeOrig = Object.prototype.hasOwnProperty.call(process.env, 'ZCLAUDE_ORIGINAL_NODE_OPTIONS');
  const originalNodeOptions = process.env.ZCLAUDE_ORIGINAL_NODE_OPTIONS;
  const preloadNodeOptions = hasNodeOrig ? process.env.NODE_OPTIONS : undefined;
  // Runs first so that Bash tools, MCP servers and subagents don't inherit the agent.
  delete process.env.ZCLAUDE_AGENT_SOCKET;
  delete process.env.ZCLAUDE_ORIGINAL_BUN_OPTIONS;
  delete process.env.ZCLAUDE_ORIGINAL_NODE_OPTIONS;
  if (hasBunOrig) {
    if (originalBunOptions) process.env.BUN_OPTIONS = originalBunOptions;
    else delete process.env.BUN_OPTIONS;
  }
  if (hasNodeOrig) {
    if (originalNodeOptions) process.env.NODE_OPTIONS = originalNodeOptions;
    else delete process.env.NODE_OPTIONS;
  }
  if (!socketPath || globalThis.__zclaudeAgentLoaded) return;
  globalThis.__zclaudeAgentLoaded = true;

  // Claude Code may replace these later, and the tap must not depend on that.
  const parseJson = JSON.parse;
  const stringify = JSON.stringify;

  const isTruthyEnv = (value) => {
    if (!value) return false;
    const lowered = String(value).trim().toLowerCase();
    return lowered !== '' && lowered !== '0' && lowered !== 'false' && lowered !== 'off';
  };

  const conn = require('node:net').connect(socketPath);
  const send = (method, params, id) => {
    try {
      conn.write(`${stringify(id === undefined ? { method, params } : { id, method, params })}\n`);
    } catch {}
  };
  conn.on('error', () => {}); // zclaude went away. Claude must carry on regardless.
  conn.unref(); // Must not keep Claude alive after /exit.
  send(
    'agent.hello',
    {
      pid: process.pid,
      bun: process.versions.bun,
      node: process.versions.node,
      code_mode: isTruthyEnv(process.env.CLAUDE_CODE_EXPERIMENTAL_CODE_MODE),
    },
    0,
  );

  // When Claude Code relaunches itself (for example toggling Code Mode on or off),
  // it spawns a replacement process with stdio: "inherit" and relaunch env markers.
  // Re-attach the preload to that replacement only, and drop this parent's socket
  // because the parent severs its own TTY input while waiting on the child.
  const patchRelaunchSpawn = (mod) => {
    if (!mod || typeof mod.spawn !== 'function' || mod.spawn.__zclaudeWrapped) return;
    const realSpawn = mod.spawn;
    const wrappedSpawn = function (command, args, options) {
      let opts = options;
      if (args && !Array.isArray(args) && typeof args === 'object') {
        opts = args;
      }
      try {
        const env = opts && typeof opts === 'object' ? opts.env : undefined;
        const isRelaunch =
          opts?.stdio === 'inherit' &&
          env &&
          (Object.prototype.hasOwnProperty.call(env, 'CLAUDE_CODE_RELAUNCH_TERMINAL_SIZE') ||
            Object.prototype.hasOwnProperty.call(env, 'CLAUDE_CODE_EXPERIMENTAL_CODE_MODE_RESTART') ||
            Object.prototype.hasOwnProperty.call(env, 'CLAUDE_CODE_EXPERIMENTAL_CODE_MODE_RESTARTED_FROM'));
        if (isRelaunch) {
          const nextEnv = { ...env, ZCLAUDE_AGENT_SOCKET: socketPath };
          if (hasBunOrig && preloadBunOptions) {
            nextEnv.BUN_OPTIONS = preloadBunOptions;
            nextEnv.ZCLAUDE_ORIGINAL_BUN_OPTIONS = originalBunOptions ?? '';
          }
          if (hasNodeOrig && preloadNodeOptions) {
            nextEnv.NODE_OPTIONS = preloadNodeOptions;
            nextEnv.ZCLAUDE_ORIGINAL_NODE_OPTIONS = originalNodeOptions ?? '';
          }
          const nextOpts = { ...opts, env: nextEnv };
          const child = Array.isArray(args) ? realSpawn.call(this, command, args, nextOpts) : realSpawn.call(this, command, nextOpts);
          try {
            conn.destroy();
          } catch {}
          return child;
        }
      } catch {}
      return realSpawn.apply(this, arguments);
    };
    wrappedSpawn.__zclaudeWrapped = true;
    try {
      mod.spawn = wrappedSpawn;
    } catch {}
  };
  try {
    patchRelaunchSpawn(require('node:child_process'));
    patchRelaunchSpawn(require('child_process'));
  } catch {}

  // Suppress blocking startup and mid-session confirmation/opt-in modals when
  // Claude reads its global config so zclaude never freezes behind a TUI
  // disclaimer dialog. Code Mode caveats are only injected when Code Mode is
  // explicitly enabled via CLAUDE_CODE_EXPERIMENTAL_CODE_MODE.
  {
    const fs = require('node:fs');
    const path = require('node:path');
    const os = require('node:os');
    const { fileURLToPath } = require('node:url');
    const codeModeRequested = isTruthyEnv(process.env.CLAUDE_CODE_EXPERIMENTAL_CODE_MODE);
    const realOrResolve = (p) => {
      const resolved = path.resolve(p);
      try {
        return fs.realpathSync(resolved);
      } catch {
        return resolved;
      }
    };
    const configDir = realOrResolve(process.env.CLAUDE_CONFIG_DIR || os.homedir());
    const cwdPaths = (() => {
      const out = [];
      try {
        const raw = process.cwd();
        out.push(raw);
        const real = realOrResolve(raw);
        if (real !== raw) out.push(real);
      } catch {}
      return out;
    })();
    const isGlobalClaudeConfig = (filePath) => {
      try {
        let p = null;
        if (typeof filePath === 'string') p = filePath;
        else if (filePath instanceof URL) p = fileURLToPath(filePath);
        else if (Buffer.isBuffer(filePath)) p = filePath.toString('utf8');
        if (!p) return false;
        const resolved = path.resolve(p);
        if (realOrResolve(path.dirname(resolved)) !== configDir) return false;
        return /^\.claude(?:-[^/]+)?\.json$/.test(path.basename(resolved));
      } catch {
        return false;
      }
    };
    const injectDialogSkips = (raw) => {
      try {
        const isStr = typeof raw === 'string';
        const text = isStr ? raw : Buffer.isBuffer(raw) ? raw.toString('utf8') : null;
        if (text === null) return raw;
        const obj = parseJson(text);
        if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return raw;
        const next = { ...obj };
        let changed = false;
        const setTrue = (key) => {
          if (next[key] !== true) {
            next[key] = true;
            changed = true;
          }
        };
        setTrue('hasAcknowledgedCostThreshold');
        setTrue('chromeInstallUpsellDismissed');
        setTrue('autoModeOptInDismissed');
        setTrue('bypassPermissionsModeAccepted');
        if (codeModeRequested) {
          setTrue('codeModeCaveatsAcceptedV1');
          setTrue('codeModeAutoModeCaveatAcceptedV1');
        }
        if (cwdPaths.length > 0) {
          const origProjects =
            next.projects && typeof next.projects === 'object' && !Array.isArray(next.projects) ? next.projects : {};
          let projects = origProjects;
          for (const dir of cwdPaths) {
            const entry =
              projects[dir] && typeof projects[dir] === 'object' && !Array.isArray(projects[dir]) ? projects[dir] : null;
            if (!entry || entry.hasTrustDialogAccepted !== true) {
              if (projects === origProjects) projects = { ...origProjects };
              projects[dir] = { ...(entry || {}), hasTrustDialogAccepted: true };
              changed = true;
            }
          }
          if (projects !== origProjects) next.projects = projects;
        }
        if (!changed) return raw;
        const patched = stringify(next);
        return isStr ? patched : Buffer.from(patched, 'utf8');
      } catch {
        return raw;
      }
    };
    const patchFs = (fsMod) => {
      if (!fsMod || fsMod.__zclaudeDialogSkipPatched) return;
      fsMod.__zclaudeDialogSkipPatched = true;
      if (typeof fsMod.readFileSync === 'function') {
        const real = fsMod.readFileSync;
        fsMod.readFileSync = function (filePath, ...rest) {
          const out = real.call(this, filePath, ...rest);
          return isGlobalClaudeConfig(filePath) ? injectDialogSkips(out) : out;
        };
      }
      if (typeof fsMod.readFile === 'function') {
        const real = fsMod.readFile;
        fsMod.readFile = function (filePath, ...rest) {
          if (!isGlobalClaudeConfig(filePath) || typeof rest[rest.length - 1] !== 'function') {
            return real.call(this, filePath, ...rest);
          }
          const cb = rest[rest.length - 1];
          rest[rest.length - 1] = function (err, data) {
            return cb.call(this, err, err ? data : injectDialogSkips(data));
          };
          return real.call(this, filePath, ...rest);
        };
      }
      if (fsMod.promises && typeof fsMod.promises.readFile === 'function' && !fsMod.promises.__zclaudeDialogSkipPatched) {
        fsMod.promises.__zclaudeDialogSkipPatched = true;
        const realP = fsMod.promises.readFile;
        fsMod.promises.readFile = function (filePath, ...rest) {
          const promise = realP.call(this, filePath, ...rest);
          if (!isGlobalClaudeConfig(filePath)) return promise;
          return promise.then((data) => injectDialogSkips(data));
        };
      }
    };
    try {
      patchFs(require('node:fs'));
      patchFs(require('fs'));
      const fsp = require('node:fs/promises');
      if (fsp && typeof fsp.readFile === 'function' && !fsp.__zclaudeDialogSkipPatched) {
        fsp.__zclaudeDialogSkipPatched = true;
        const realP = fsp.readFile;
        fsp.readFile = function (filePath, ...rest) {
          const promise = realP.call(this, filePath, ...rest);
          if (!isGlobalClaudeConfig(filePath)) return promise;
          return promise.then((data) => injectDialogSkips(data));
        };
      }
    } catch {}
  }

  let incoming = '';
  conn.on('data', (chunk) => {
    incoming += chunk.toString('utf8');
    let end;
    while ((end = incoming.indexOf('\n')) >= 0) {
      const line = incoming.slice(0, end);
      incoming = incoming.slice(end + 1);
      try {
        handle(parseJson(line));
      } catch {}
    }
  });

  function handle(message) {
    if (message.method === 'agent.input') {
      // Enters the same stream the TUI reads keystrokes from.
      process.stdin.push(Buffer.from(message.params.data, 'base64'));
    } else if (message.method === 'agent.memory') {
      let heap_size = 0;
      let object_count = null;
      let top_object_types = {};
      if (process.versions.bun) {
        const { heapStats } = require('bun:jsc');
        const stats = heapStats();
        heap_size = stats.heapSize;
        object_count = stats.objectCount;
        const top = Object.entries(stats.objectTypeCounts).sort((a, b) => b[1] - a[1]).slice(0, 12);
        top_object_types = Object.fromEntries(top);
      } else {
        const stats = require('node:v8').getHeapStatistics();
        heap_size = stats.used_heap_size;
      }
      send('agent.reply', {
        request: message.params.request,
        result: {
          pid: process.pid,
          usage: process.memoryUsage(),
          heap_size,
          object_count,
          top_object_types,
        },
      });
    }
  }

  // Links each response stream to the request that caused it. The SDK serializes the
  // body just before sending, in the same async flow that later reads the response,
  // so tagging that flow here makes the tag readable when the stream opens.
  const { AsyncLocalStorage } = require('node:async_hooks');
  const { createHash } = require('node:crypto');
  const fingerprint = (text) => createHash('sha256').update(text).digest('hex').slice(0, 16);
  // What kind of agent made a request. The first system block is left out when there
  // are multiple blocks because it carries per-request dynamic data.
  const shapeOf = (body) => {
    if (!Array.isArray(body.tools) || body.tools.length === 0) return undefined;
    const system = Array.isArray(body.system)
      ? (body.system.length > 1 ? body.system.slice(1) : body.system)
          .map((block) => (typeof block === 'string' ? block : block?.text ?? ''))
          .join('\n')
      : typeof body.system === 'string'
        ? body.system
        : '';
    const tools = body.tools.map((tool) => tool?.name ?? tool?.type ?? '').sort().join('\n');
    return { tools: fingerprint(tools), system: fingerprint(system) };
  };
  const hasCodeModeTool = (body) =>
    Array.isArray(body.tools) && body.tools.some((tool) => tool?.name === 'REPL' || tool?.name === 'Eval');
  const requestLink = new AsyncLocalStorage();
  const realJsonStringify = JSON.stringify;
  JSON.stringify = function (value, ...rest) {
    try {
      if (value && typeof value === 'object' && Array.isArray(value.messages) && typeof value.model === 'string' && 'max_tokens' in value) {
        requestLink.enterWith({
          thread: Boolean(value.thread),
          previous: value.thread?.previous_message_id,
          shape: shapeOf(value),
          codeMode: Array.isArray(value.tools) && value.tools.length > 0 ? hasCodeModeTool(value) : undefined,
        });
      }
    } catch {}
    return realJsonStringify.call(this, value, ...rest);
  };

  let nextStream = 0;
  const seenMessageIds = new Set();
  const isDuplicateMessage = (id) => {
    if (!id) return false;
    if (seenMessageIds.has(id)) return true;
    seenMessageIds.add(id);
    if (seenMessageIds.size > 1024) {
      seenMessageIds.delete(seenMessageIds.values().next().value);
    }
    return false;
  };

  // One tap per response reader, which is what keeps concurrent streams apart.
  function makeTap(link) {
    const decoder = new TextDecoder();
    let buffer = '';
    let isModelStream = null;
    let stream = 0;
    let stopped = false;

    const onFrame = (frame) => {
      const line = frame.split('\n').find((l) => l.startsWith('data: '));
      if (!line) return;
      const event = parseJson(line.slice(6));
      if (event.type === 'ping') return;
      // A response piped or teed into a second ReadableStream replays the same
      // SSE bytes with the same message id; only the first tap should report it.
      if (event.type === 'message_start' && isDuplicateMessage(event.message?.id)) {
        isModelStream = false;
        buffer = '';
        return;
      }
      if (!stream) stream = ++nextStream;
      if (event.type === 'message_stop') stopped = true;
      const delta = event.delta ?? {};
      const usage = event.type === 'message_start' ? event.message?.usage : undefined;
      send('agent.stream', {
        stream,
        type: event.type,
        message_id: event.message?.id,
        model: event.message?.model,
        in_thread: link?.thread,
        previous_message_id: link?.previous,
        shape: event.type === 'message_start' ? link?.shape : undefined,
        code_mode: event.type === 'message_start' ? link?.codeMode : undefined,
        cache_read_tokens: usage?.cache_read_input_tokens,
        cache_write_tokens: usage?.cache_creation_input_tokens,
        index: event.index,
        block_type: event.content_block?.type,
        tool: event.content_block?.name,
        delta_type: delta.type,
        text: delta.text ?? delta.thinking ?? delta.partial_json,
        stop_reason: delta.stop_reason,
      });
    };

    return {
      feed(bytes) {
        if (isModelStream === false) return;
        buffer += decoder.decode(bytes, { stream: true });
        if (isModelStream === null) {
          if (buffer.length < 16) return;
          isModelStream = buffer.includes('event: message_start') || buffer.includes('event: ping');
          if (!isModelStream) {
            buffer = '';
            return;
          }
        }
        let end;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          try {
            onFrame(frame);
          } catch {}
          if (isModelStream === false) return;
        }
      },
      finish() {
        if (isModelStream && stream) send('agent.stream', { stream, type: 'stream_end', stopped });
        isModelStream = false;
      },
    };
  }

  const asBytes = (value) => {
    if (value instanceof Uint8Array) return value;
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    return null;
  };

  const tappedStreams = new WeakSet();
  const proto = ReadableStream.prototype;
  const realGetReader = proto.getReader;
  proto.getReader = function (...args) {
    const reader = realGetReader.apply(this, args);
    if (args[0]?.mode === 'byob' || tappedStreams.has(this)) return reader;
    tappedStreams.add(this);
    const tap = makeTap(requestLink.getStore());
    const realRead = reader.read;
    const realCancel = reader.cancel;
    reader.read = function () {
      return realRead.call(this).then(
        (result) => {
          // The tap must never disturb the stream Claude Code is reading.
          try {
            if (result.done) tap.finish();
            else {
              const bytes = asBytes(result.value);
              if (bytes) tap.feed(bytes);
            }
          } catch {}
          return result;
        },
        (err) => {
          tap.finish();
          throw err;
        },
      );
    };
    reader.cancel = function (...cancelArgs) {
      tap.finish();
      return realCancel.apply(this, cancelArgs);
    };
    return reader;
  };

  // On Node.js (undici), `for await` on `response.body` iterates via
  // `[Symbol.asyncIterator]` / `values()` without calling JS-level `getReader()`.
  // Native Bun builds read responses through `getReader()` inside the request's
  // AsyncLocalStorage context, so wrapping `[Symbol.asyncIterator]` there would
  // race a second tap outside that context.
  if (!process.versions.bun) {
    const wrapAsyncIterator = (realMethod) =>
      function (...args) {
        const iter = realMethod.apply(this, args);
        if (!iter || typeof iter.next !== 'function' || tappedStreams.has(this)) return iter;
        tappedStreams.add(this);
        const tap = makeTap(requestLink.getStore());
        const realNext = iter.next;
        const realReturn = iter.return;
        const realThrow = iter.throw;
        iter.next = function (...nextArgs) {
          return realNext.apply(this, nextArgs).then(
            (result) => {
              try {
                if (result.done) tap.finish();
                else {
                  const bytes = asBytes(result.value);
                  if (bytes) tap.feed(bytes);
                }
              } catch {}
              return result;
            },
            (err) => {
              tap.finish();
              throw err;
            },
          );
        };
        if (typeof realReturn === 'function') {
          iter.return = function (...retArgs) {
            tap.finish();
            return realReturn.apply(this, retArgs);
          };
        }
        if (typeof realThrow === 'function') {
          iter.throw = function (...throwArgs) {
            tap.finish();
            return realThrow.apply(this, throwArgs);
          };
        }
        return iter;
      };

    const realAsyncIter = proto[Symbol.asyncIterator];
    const realValues = proto.values;
    if (typeof realAsyncIter === 'function') {
      const wrapped = wrapAsyncIterator(realAsyncIter);
      proto[Symbol.asyncIterator] = wrapped;
      if (realValues === realAsyncIter) proto.values = wrapped;
      else if (typeof realValues === 'function') proto.values = wrapAsyncIterator(realValues);
    }
  }
})();
