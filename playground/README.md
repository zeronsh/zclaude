# zclaude playground

A web UI for one headless zclaude session: the conversation on the left, the real
Claude Code terminal on the right. It is only a consumer of zclaude. It talks to
`zclaude --stdio` through `@zclaude/client`, and zclaude itself is unchanged and
doesn't need it.

From the repo root:

```
bun install                       # every workspace
make -C zclaude                   # zclaude/bin/zclaude
cd playground
bun run build                     # the frontend, into dist/
bun server.ts --port 7777 --cwd ~/some/project -- --model haiku
```

It prints `http://127.0.0.1:7777/?t=TOKEN`. Open that URL.

| Flag | |
| --- | --- |
| `--port` | Default 7777. Loopback only. |
| `--bin` | The zclaude binary. Default `../zclaude/bin/zclaude`, then `$ZCLAUDE_BIN`, then `zclaude` on `PATH`. |
| `--cwd` | Where Claude Code runs. Default: the current directory. |
| `-- …` | Passed on to `claude`. |

`bun run start` serves the existing build. For hot reload, run `bun run dev` alongside
`bun server.ts --port 7777` and open `http://localhost:5173/?t=TOKEN`.

## How it works

- **Server (`server.ts`):** spawns `zclaude --stdio` and subscribes with `term: true`.
  zclaude stores nothing, so storage is the server's own choice. It folds events into
  one `SessionStore`, bounded to the last 5000 entries, with streamed text dropped
  once the transcript holds it. Each browser that connects gets that state, then live
  events, so a reload rebuilds the conversation and memory stays bounded however long
  the session runs. The terminal is redrawn from `screen({ ansi: true })` instead,
  then follows live output.
- **One WebSocket (`/ws`):** carries events, terminal bytes and RPC. Browsers may call
  only the public methods (`prompt.send`, `command`, `interrupt`, `dialog.respond`,
  `model.set`, `mode.set`, `keys`, `term.write`, `term.resize`, `screen`, `status`,
  `memory`). xterm's own replies to terminal queries are dropped, because Claude asked
  the PTY, not the browser.
- **Browser:**
  - `SessionStore` from `@zclaude/client/store` folds events into one view, which is
    read at most once per frame.
  - `src/model.ts` turns that view into rows. `src/rows.tsx` draws them in a Mugen
    `MugenVList`, so every row height is computed. The list sticks to the bottom, and its
    runway lets the latest prompt reach the top.
  - `src/dock.tsx` answers questions, permissions, plans (rendered as markdown, with
    the terminal card's own choices), MCP elicitations, and any other card the
    terminal shows.
- **Security:** this page hands out a shell-equivalent terminal. The server binds to
  127.0.0.1, and every route needs the token, from the URL or from the cookie the page
  sets. Treat the URL like a password.

The UI is plain shadcn/ui (neutral theme, light or dark from the system), Tailwind v4,
and lucide icons. `window.__zclaude.text()` returns the conversation as text, for
debugging.

## Tests

```
bun test src      # row model, tool descriptions, and store → rows from protocol events
bunx tsc --noEmit
```
