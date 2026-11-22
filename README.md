# zclaude

zclaude runs the **interactive** Claude Code CLI (`claude`, whatever version is on
your `PATH`) unchanged, and makes it fully drivable from outside. Everything the
session does is forwarded as JSON-RPC 2.0 notifications over newline-delimited
JSON, and everything a person at the terminal can do is a method call: send
prompts and slash commands, answer permission, question, plan and MCP dialogs,
switch models and permission modes, press keys, read the screen.

```
zclaude [claude args]                 use it exactly like `claude`; a control socket opens
zclaude --stdio [claude args]         headless: zclaude owns the terminal, JSON-RPC on stdin/stdout
zclaude ctl <command>                 drive a running session from a shell
```

**No storage.** zclaude keeps only what it needs to act correctly right now: open
dialogs, prompts in flight, streams still receiving tokens, the terminal screen.
Everything else is forwarded as it happens and forgotten. Claude Code already
writes the conversation to its own transcript, and every consumer wants something
different kept (a UI wants rendered rows, a bot wants the last reply, an audit log
wants everything), so the consumer decides. `@zclaude/client` ships an optional
in-memory reducer (`SessionStore`) for consumers that want the session as one value.

**Never stuck behind a dialog.** Permission, question, plan and elicitation dialogs
are answered over RPC while the terminal shows them too (see
[the hook race](#the-hook-race)). Any other selection card on the terminal (a model
picker, a card whose hook has gone, anything a future version adds) is reported as a
`terminal` dialog and answered by choice number. Nothing is ever typed while a card
is up, where Enter would pick its first choice. Start-up and opt-in modals (trust
this folder, cost threshold, auto-mode opt-in, bypass-permissions confirmation) are
suppressed, and model switches skip their confirmation. `screen` and `keys` reach
everything else.

The repo:

| Path | |
| --- | --- |
| `zclaude/` | The Odin program. A single-threaded poll loop, no dependencies beyond libc. |
| `packages/client/` | `@zclaude/client`: a dependency-free TypeScript client (`Peer`, `ZClaude.spawn/connect`, protocol types, `SessionStore`). |
| `playground/` | A web UI for one headless session, built only on `@zclaude/client`. See [its README](playground/README.md). |

## Install and build

Needs [Odin](https://odin-lang.org) `dev-2026-11` or later (`brew install odin`, or a
release from GitHub), [Bun](https://bun.sh) ≥ 1.3 for the client, tests and
playground, and a logged-in `claude`.

```sh
make -C zclaude                 # zclaude/bin/zclaude (vetted: -vet-unused -vet-shadowing)
make -C zclaude release         # optimized, stripped
make -C zclaude install         # release build into $PREFIX/bin (default ~/.local/bin)
make -C zclaude test            # unit tests
bun install && bun run typecheck
bun test --timeout 240000 zclaude/tests    # integration tests against real Claude Code (Haiku)
```

Run on Linux x86_64 with Claude Code 2.1.330. It builds for macOS (arm64) too, where earlier versions were run.

zclaude finds `claude` on `PATH` at every launch, so it follows updates
(`ZCLAUDE_CLAUDE_BIN` overrides). Started from inside another Claude Code session,
it strips the nested-session environment (`CLAUDECODE` and related variables).

## Running it

### Interactive

`zclaude [claude args]` is `claude` with a remote control. The real terminal works
exactly as before (Ctrl-Z job control included) and a control socket opens at
`~/.zclaude/run/<pid>.sock`, or `--socket PATH`. Subcommands, `-p`, `--version`
and non-terminal use go straight to `claude`.

### Headless

`zclaude --stdio [--size 120x40] [claude args]` starts Claude Code on a pseudo
terminal that zclaude owns and speaks JSON-RPC on stdin/stdout. This is how
programs use it. The process that started it owns the session: it is subscribed
from the first event, and when its stdin closes the session shuts down. The socket
opens too, so others can attach; `--no-socket` keeps it private.

```ts
import { ZClaude, SessionStore } from '@zclaude/client';

const z = ZClaude.spawn({ cwd: '/my/project', args: ['--model', 'haiku'] });
await z.ready;
z.on('entry', (entry) => entry.role === 'assistant' && console.log(entry.text));
z.on('dialog.open', (dialog) => dialog.kind === 'permission' && z.respond(dialog.id, { decision: 'allow' }));
await z.send('Create hello.txt containing hi');
await z.waitFor('state', (p) => p.state === 'idle');
console.log(await z.shutdown()); // 0
```

zclaude's own flags go before `claude`'s (or before `--`):

| Flag | |
| --- | --- |
| `--stdio` | Headless, JSON-RPC on stdin/stdout. |
| `--size COLSxROWS` | The headless terminal's size. Default `120x40`. |
| `--socket PATH` | Where the control socket listens. |
| `--no-socket` | No control socket (hooks then use a private one). |
| `--code-mode` | Sets `CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1`. |
| `--log PATH` | zclaude's debug log. |

Your own `--settings` (a file or JSON) is merged with zclaude's hooks, since Claude
Code takes only one.

### `zclaude ctl`

```
zclaude ctl [--socket PATH] <command>

  list                            live sessions
  status                          the snapshot, as JSON
  send [--hook] TEXT              send a prompt
  command /NAME [ARGS]            run a slash command, e.g. /compact
  model [NAME]                    show or switch the model
  mode NAME                       default | acceptEdits | plan | auto | dontAsk | bypassPermissions
  interrupt                       end the turn, or refuse the open dialog
  answer DIALOG_ID JSON           e.g. '{"answers":[{"selected":["Green"]}]}', '{"decision":"allow"}'
  keys KEY...                     enter, esc, shift+tab, up, ctrl+c, ... or text:WORDS
  screen                          the terminal screen as text
  subscribe [--term] [--history]  print events as JSON lines
  memory                          heap statistics from inside Claude's process
  shutdown [--force]              end the session
  call METHOD [JSON]              any method
```

Without `--socket`, the most recently started live session is used.

## The protocol

JSON-RPC 2.0, one JSON object per line, UTF-8, over the stdio of `zclaude --stdio`
or a session's Unix socket. Requests carry an `id` and get exactly one reply.
Events are notifications: `method` is the event type and `params` always starts
with `seq`. `packages/client/src/protocol.ts` has every type below.

### Methods

| Method | Params | Result |
| --- | --- | --- |
| `status` | | The [snapshot](#snapshot). |
| `subscribe` | `term?: bool`, `history?: bool` | The snapshot. Events follow. `history` first replays the conversation so far as `entry` events with `historic: true`. `term` adds `term.output`, starting with a full redraw of the current screen (`redraw: true`). |
| `unsubscribe` | | `true` |
| `prompt.send` | `text`, `transport?: "inproc" \| "hook"`, `images?: [{path} \| {data, media_type?}]` | `{prompt_id, status, transport}` |
| `command` | `text` (starts with `/`) | `{prompt_id, status}` |
| `interrupt` | | `{sent, via?: "esc" \| "dialog", state?}` |
| `dialog.respond` | `id` and a [response](#dialogs) | `{dialog_id, status, mode?, prompt_id?}` |
| `model.set` | `model` | `{model, status: "switching"}`; `meta` follows with the result |
| `effort.set` | `level`: `low` \| `medium` \| `high` \| `xhigh` \| `max` | `{effort, status: "switching"}`; `meta.effort` follows |
| `task.stop` | `id` (from `tasks`) | `{task_id, stopped: true}` once its row has gone from /tasks |
| `mode.set` | `mode` | `{mode}` once the footer shows it |
| `keys` | `keys: [name \| {text} \| {key}]`, `delay_ms?` (60), or `text`, or `data` (base64) | `true` |
| `term.write` | `data` (base64) or `text` | `true` |
| `term.resize` | `cols`, `rows` (headless only) | `true` |
| `screen` | `ansi?: bool` | `{cols, rows, cursor, alt_screen, bracketed_paste, lines, permission_mode?, ansi?}` |
| `memory` | | Claude's `process.memoryUsage()`, heap size and object counts |
| `shutdown` | `force?: bool` | `{stopping: "graceful" \| "hangup" \| "kill" \| "exited"}` |

Errors are JSON-RPC errors: `-32700` parse error, `-32601` unknown method, `-32000`
everything else, with a message saying what to do instead.

**Prompts.** `inproc` (the default) types the prompt into the TUI from inside
Claude's process, as a bracketed paste and then Enter: a real user turn, exactly as
if typed. It waits (`queued`) while the session starts, while a dialog is open, and
while an answered dialog's card is still leaving the screen, so it can never be
typed into a dialog. `hook` hands the prompt to a waiting `asyncRewake` hook
instead, which works without the in-process agent; Claude sees it wrapped in a
system reminder. A prompt goes `queued` → `delivered` (typed or handed over) →
`received` (seen in the transcript), or `failed`.

**Images** attach the way a file dropped on the terminal does: zclaude pastes each
path on its own, which the prompt box turns into `[Image #N]`, then the text. `data`
(base64 png, jpeg, gif or webp) is written to a private file in `~/.zclaude/run`
that lives as long as the session. Claude receives the image itself, not a path to
read.

**Effort** is `/effort LEVEL` typed at the terminal; Claude Code also saves it as
the default for new sessions, as it does there. `meta.effort` comes from the level
every hook reports.

**Stopping a task** does what a person does: zclaude opens `/tasks`, moves to the
task's row, presses `x` and closes the view, reading the screen before each step.

**Keys** are named like `enter`, `esc`, `tab`, `shift+tab`, `up`, `down`, `left`,
`right`, `home`, `end`, `pageup`, `pagedown`, `backspace`, `delete`, `space`,
`shift+enter`, `ctrl+<letter>`, `alt+<key>`. `{text}` types literal text.

**Modes.** `mode.set` presses Shift+Tab until the footer shows the target, waiting
out any closing dialog first (Shift+Tab on a plan card would answer it). It fails if
the target isn't in this session's cycle (for example `bypassPermissions` without
`--allow-dangerously-skip-permissions`).

**Shutdown** ends the session the way a person would: open dialogs are refused,
a running turn is stopped with Esc, and `/exit` is typed, so Claude Code runs its
`SessionEnd` hooks and exits 0. If that hasn't happened within 6 s, zclaude sends
SIGHUP, and SIGKILL to Claude's process group 4 s later. `force`, or asking again,
skips ahead a stage. The same happens when the owner of a headless session closes
its stdin or zclaude gets SIGTERM, SIGINT or SIGHUP.

### Events

| Event | Params (besides `seq`) |
| --- | --- |
| `ready` | `snapshot`. Headless only, first, to the owner. |
| `state` | `state`, `previous`. States: `starting`, `idle`, `busy`, `awaiting_input` (a dialog is open), `ended` (SessionEnd ran), `exited`. |
| `meta` | Only the [meta](#snapshot) fields that changed. |
| `hook` | `name` (the Claude Code hook event), and when present: `tool`, `tool_use_id`, `agent_id`, `agent_type`, `source`, `notification_type`, `message` (Notification only). |
| `prompt` | `id`, `text`, `transport`, `status`, `error?` |
| `entry` | A conversation line from Claude's transcript: `uuid`, `session_id`, `role` (`user` \| `assistant` \| `system`), `origin`, `timestamp`, `text`, `blocks` (content blocks; signatures and image data removed, strings over 32 KB cut), `model?`, `message_id?` (assistant), `prompt_id?` (the prompt it carried), `sidechain`, `historic?`. |
| `stream.start` | `stream` (a number), `message_id`, `model`, `main` (part of the main conversation, not a subagent or background call), `in_thread`, `previous_message_id?`, `in_transcript`, `started_at`, `usage` |
| `stream.block` | `stream`, `index`, `type` (`text` \| `thinking` \| `tool_use` \| ...), `name?` (tool), `started_at` |
| `stream.delta` | `stream`, `index`, `text` (text, thinking, or partial tool-input JSON) |
| `stream.block_stop` | `stream`, `index`, `ended_at` |
| `stream.usage` | `stream`, `usage` (the running output count, with the input side) |
| `stream.stop_reason` | `stream`, `stop_reason` |
| `stream.end` | `stream`, `status` (`done` \| `aborted`), `ended_at` |
| `stream.confirmed` | `stream`, `message_id`: the transcript now holds this message. |
| `dialog.open` | A [dialog](#dialogs). |
| `dialog.update` | `id`, `status`, and whichever changed: `held`, `touched`, `modes`, or how it closed: `resolved_by` (`rpc` \| `terminal`; absent when a turn or session ending closed it), `answers`. |
| `term.output` | `data` (base64 terminal bytes), `redraw?`. Only for `subscribe({term: true})`. |
| `term.resize` | `cols`, `rows` |
| `turn.start` | `turn` (a number), `claude_prompt_id?` (Claude Code's id for the prompt), `started_at` |
| `turn.end` | `turn`, `status` (`done` \| `interrupted` \| `error` \| `exited`), `stop_reason?`, `claude_prompt_id?`, `prompt_ids` (zclaude prompts it took in), `started_at`, `ended_at`, `duration_ms`, `messages` (main model calls), `usage`, `error?`, `error_details?`, `last_message?` |
| `activity` | `activity`, `tool?`, `since`, `retry_at?`: see [activity](#turns-and-activity) |
| `api.retry` | `status?`, `error?`, `attempt?`, `max_attempts?`, `retry_in_ms`: Claude Code is retrying a failed API call |
| `agent.start` | `agent_id`, `agent_type`, `parent_tool_use_id?` (the Agent call that started it), `internal` |
| `agent.stop` | the same, and `last_message?` |
| `tasks` | `tasks`: the background tasks (`id`, `type`, `status`, `description`, `command?`, `agent_type?`, …) |
| `exit` | `code` (Claude's exit code, 128 + n for signal n), `signal?` (e.g. `"SIGHUP"`). Last, and sent to every control connection. |

A subagent's entries carry `agent_id` and `parent_tool_use_id`, with `sidechain: true`.

`usage` objects are `{input_tokens, output_tokens, cache_read_input_tokens,
cache_creation_input_tokens}`.

`origin` says where an entry came from: `terminal` (typed at the terminal),
`external` (a prompt sent through zclaude), `notification` (a background-task
notification), `tool_result`, `command` (slash-command input and output), `meta`,
`interrupt`, `system` (compaction, API errors), `assistant`.

Times (`started_at`, `ended_at`, `created_at`) are Unix milliseconds.

### Snapshot

What `ready`, `status` and `subscribe` return: everything needed to pick up a
session in progress.

```jsonc
{
  "protocol": 1, "seq": 42, "pid": 1234, "mode": "stdio" /* or "interactive" */,
  "socket": "/Users/me/.zclaude/run/1234.sock", "state": "idle",
  "meta": {
    "session_id": "…", "transcript_path": "…", "cwd": "…",
    "model": "claude-haiku-5-5", "model_pending": "", "model_error": "",
    "code_mode": false, "permission_mode": "default",
    "agent_connected": true,       // the in-process agent (token streams, inproc prompts)
    "hook_waiter_armed": true,     // a rewake hook is waiting for `hook` prompts
    "effort": "medium",
    "context_tokens": 41057,       // the main conversation's context, as of its last message
    "cost_usd": null               // the session's cost, once Claude Code records it
  },
  "activity": { "activity": "idle", "since": 1763000000000 },
  "turn": null,                    // or { "turn": 3, "claude_prompt_id": "…", "started_at": … }
  "tasks": [ /* background tasks */ ],
  "agents": [ /* subagents running now */ ],
  "dialogs": [ /* open dialogs */ ],
  "prompts": [ /* prompts not yet received */ ],
  "streams": [ { "stream": 3, "message_id": "…", "model": "…", "main": true, "status": "streaming",
                 "started_at": 0, "blocks": [ { "index": 0, "type": "text", "name": "", "text": "So far…", "started_at": 0 } ] } ],
  "term": { "cols": 120, "rows": 40 }
}
```

### Turns and activity

zclaude puts together what the session is doing from all of its sources at once:
the hooks (exact and ordered, each carrying Claude Code's own `prompt_id` and effort
level), the API stream inside Claude's process (tokens and usage), the transcript
(the record, ending each turn with Claude Code's own `turn_duration` line) and the
screen.

- A **turn** starts with a prompt (or a background notification Claude picks up)
  and ends at Stop, StopFailure or an interrupt. `turn.end` waits for the
  transcript's end marker (2 s at most), so **every `entry` of a turn comes before
  its `turn.end`**, with the turn's usage, its last message and how it ended.
  `state: idle` stays immediate.
- **`activity`** says what is happening now: `starting`, `idle`, `requesting` (a
  model call with no tokens yet), `thinking`, `responding`, `calling` (the model is
  writing a call to `tool`), `tool` (running `tool`), `retrying` (until
  `retry_at`), `compacting`, `waiting` (a dialog), `exited`.
- **Retries**: when an API call fails, Claude Code retries by itself and says so
  only on screen ("529 Overloaded · retrying in 8s · attempt 3/10"). No hook fires
  and the transcript records nothing, so zclaude reads it there and reports
  `api.retry` and `activity: retrying`.
- **Subagents**: `agent.start` and `agent.stop`, linked to the Agent call that
  started them (from Claude Code's own metadata file). Their transcripts are
  forwarded as entries, all before `agent.stop`. Claude Code's own helpers (prompt
  suggestions and the like) come as `internal: true` and aren't forwarded.
- **Background tasks**: `tasks` comes with every Stop and SubagentStop, and when
  `task.stop` removes one.
- `meta.context_tokens` sizes the main conversation after each of its messages, and
  `meta.cost_usd` is the session's cost once Claude Code records it (at the end of
  the session in this version).

### Dialogs

```jsonc
{
  "id": "toolu_…",          // the tool_use_id; perm-N or elicit-N when there is none
  "kind": "permission",     // question | permission | plan | elicitation | terminal
  "tool": "Bash",           // AskUserQuestion, ExitPlanMode, …; "" for elicitation
  "input": { "command": "touch a.txt" },
  "suggestions": [],        // the rules "always allow" would add (permission_suggestions)
  "status": "open",
  "created_at": 1763000000000,
  "held": true,             // zclaude can still answer it; false once only the terminal can
  "touched": false,         // someone pressed keys in the terminal while it was open
  "modes": ["auto", "default"]  // plan only: the card's approve choices, filled in by dialog.update
}
```

| Kind | Responses (`dialog.respond` params besides `id`) | Closes as |
| --- | --- | --- |
| `question` | `{answers: [{selected: [labels], other?: text, notes?: text}, …]}` (one per question), or `{answers: {"<question>": "<answer>"}}`, with an optional `response` (a free reply to the whole card); or `{decision: "cancel", message?, interrupt?}` | `answered`, `cancelled` |
| `permission` | `{decision: "allow", updated_input?, updated_permissions?, mode?}`, `{decision: "allow_always", mode?}` (applies `suggestions`), `{decision: "deny", message?, interrupt?}` | `allowed`, `denied` |
| `plan` | `{decision: "approve", mode?, plan?, message?}`, `{decision: "reject", message?, interrupt?}` | `approved`, `rejected` |
| `elicitation` | `{action: "accept", content?}`, `{action: "decline"}`, `{action: "cancel"}` | `accepted`, `declined`, `cancelled` |
| `terminal` | `{option: N, text?}` (its choice number, from 1; `text` for a choice that takes text), `{decision: "cancel"}` (Esc) | `answered`, `cancelled`, `closed` (went away by itself) |

A `terminal` dialog's `input` is `{text, options}`: the card's lines as shown and
its choice labels. One opens when a selection card has been on screen for 0.6 s with
no hook behind it. Any dialog that is no longer `held` also takes `{option: N}`,
which picks that choice on its card. It then closes when Claude Code reports the
tool's outcome, and the result's status is `sent`.

`allow_always` applies the dialog's `suggestions`, which is what the card's "Yes, and
always allow ..." choice does. Claude Code decides what they are (rules,
directories, sometimes a mode) and where they're kept. `mode` also switches the
permission mode, like the card's "Yes, and switch to auto mode". A `deny` with a
`message` reaches Claude worded exactly as the card's "tell Claude what to do
differently".

A single-select question takes exactly one option or free text; multi-select takes
any options plus free text, joined with ", " as the terminal does.

Plans mirror the terminal card. `modes` lists its approve choices in order (they
depend on what the session allows: "Yes, and use auto mode" when auto mode is
available, otherwise "Yes, auto-accept edits", then "Yes, manually approve edits",
and bypass permissions when enabled). `approve` without `mode` takes the first, as
Enter would. `plan` replaces the plan with an edited one. `message` is feedback with
the approval (the card's "shift+tab to approve with this feedback"). A hook can't
attach that, so it follows as the next prompt and its `prompt_id` is in the result.
`reject` with a `message` is "Tell Claude what to change": Claude stays in plan mode
and revises. `interrupt` also ends the turn, like Esc on the card. If the card
offers no approve choice (a plan Claude Code can't show), `modes` stays empty.

`interrupt` with a dialog open refuses every held dialog and ends the turn.
A dialog that is no longer `held` can only be answered at the terminal (read it
with `screen`, answer with `keys`).

### Ordering

- `seq` increases by one per event zclaude produces. A connection sees only the
  events it subscribed to, so it can see gaps.
- On one connection, the events a request causes come before its reply (for
  example `dialog.update` before the `dialog.respond` result).
- Within one source, order is kept: hooks in the order Claude Code ran them, entries
  in transcript order, and each stream's events in order.
- **Across sources, order is not guaranteed.** Hooks, the transcript and the token
  stream reach zclaude independently. An assistant `entry` can arrive after the
  `state: idle` that ends its turn, and `stream.end` after its `entry`. Wait for
  what you need explicitly: for example, after `idle`, wait for the `entry` whose
  `message_id` matches each main stream that ended `done`.
- A prompt's `received` comes just before the `entry` that carries its
  `prompt_id`.
- Every `entry` of a turn comes before its `turn.end`, and every entry of a
  subagent before its `agent.stop`.
- `dialog.open` comes before any `dialog.update` for that id, and each dialog closes
  exactly once.
- `exit` is the last event.

### Security

Whoever can reach a session's socket can drive the session, which means running
commands as you. Sockets live in `~/.zclaude/run` (mode 0700) and are created with
mode 0600 (`--socket PATH` too). The in-process agent sends zclaude token events
and one-way fingerprints of each request's tool names and system prompt, never
headers or message bodies, so credentials and prompts stay in Claude's process.
The playground binds to 127.0.0.1 only and every route needs a random token from
the URL it prints; treat that URL like a password.

## Using zclaude as a harness

A control plane that already drives Claude Code through `claude -p --input-format
stream-json` (the Agent SDK's transport) can use zclaude for what that mode can't
do: Code Mode (Claude Code refuses it without a terminal), attaching to a session a
person is running, and anything only the terminal UI offers. What each piece of a
stream-json harness maps to:

| stream-json | zclaude |
| --- | --- |
| user message line on stdin | `prompt.send` (with `images`) |
| `result` frame (end of turn, usage, stop reason, error) | `turn.end` |
| per-message `command_lifecycle` | `prompt` statuses (`queued` → `delivered` → `received`) and `turn.end.prompt_ids` |
| assistant/user frames | `entry`, and `stream.*` for tokens |
| `parent_tool_use_id` on subagent frames | `agent_id` and `parent_tool_use_id` on entries and hooks; `agent.start`/`agent.stop` |
| `can_use_tool` control request | `dialog.open` / `dialog.respond` |
| `interrupt` | `interrupt` |
| `set_model`, `apply_flag_settings` (effort) | `model.set`, `effort.set` |
| `set_permission_mode` | `mode.set` |
| `background_tasks_changed`, `stop_task` | `tasks`, `task.stop` |
| `initialize` (commands, models) | unchanged: a short `claude -p` probe gives the catalogs for any session |
| `api_retry` | `api.retry`, `activity: retrying` |

Slash commands and skills run with `command` (`/name args`), as typed.

## How it works

```
             ┌──────────── zclaude (one thread, poll loop) ────────────┐
 consumers ⇄ │ JSON-RPC: stdio │ ~/.zclaude/run/<pid>.sock              │
             │                 ▲            ▲              ▲            │
             │  PTY ⇄ screen model     hook clients     agent client    │
             └────┬────────────────────────┬──────────────┬────────────┘
                  │ terminal bytes          │ zclaude __hook (one process per hook)
             ┌────▼─────────────────────────┴──────────────┴───────────┐
             │ claude (interactive TUI) + agent.js preloaded in-process  │
             └─────────────────────────────────────────────────────────┘
```

- **Hooks** (`--settings`): every lifecycle hook runs `zclaude __hook event`, which
  reports to the socket and waits for the reply so hooks stay in order. They give
  state, tool calls, the transcript path and the permission mode.
- **Transcript**: zclaude tails Claude's JSONL transcript and forwards conversation
  lines as `entry` events.
- **Agent** (`agent.js`, preloaded with `BUN_OPTIONS=--preload` or
  `NODE_OPTIONS=--require`): taps the API's SSE streams for token-level events,
  types `inproc` prompts with `process.stdin.push`, answers `memory`, and skips the
  start-up modals. It removes itself from the environment so tools and subagents
  don't inherit it.
- **Screen**: a VT model of the terminal, so `screen` returns text, a terminal that
  attaches late gets an ANSI redraw, and the footer gives the permission mode.

### The hook race

Dialogs are answered through a *held* `PermissionRequest` hook (and an
`Elicitation` hook). The hook process connects to zclaude and blocks until a
consumer calls `dialog.respond`. Claude Code shows its own dialog in the TUI at the
same time, so the person at the terminal and the consumer race, and whoever answers
first wins:

- **RPC first:** zclaude replies to the hook with the decision, and Claude Code acts
  on it and takes its card down. zclaude holds typed input for that card for up to
  3 s, until the tool reports back (PostToolUse, PostToolUseFailure,
  PermissionDenied, ElicitationResult) or the turn ends, so a queued prompt or a
  mode change never lands in a card that is still on screen. For the same reason, a
  prompt's Enter is held if a card opens between its paste and its Enter, so a card
  can never take it as "Yes". Beyond the hooks, zclaude reads the screen: while any
  selection card is drawn (numbered choices with a `❯`, in place of the prompt box
  and its mode footer), nothing is typed, not even `/exit` at shutdown.
- **Terminal first:** Claude Code stops the hook. zclaude sees the disconnect and
  reports `held: false`, and the tool's PostToolUse closes the dialog with
  `resolved_by: "terminal"`.

`PermissionRequest` carries no `tool_use_id`, so zclaude links it to the PreToolUse
before it by tool name and canonical input JSON, or uses a synthetic `perm-N` id
(Code Mode's inner calls ask without a PreToolUse).

Tools that need a person, such as AskUserQuestion and ExitPlanMode, only accept a
hook's allow when it carries `updatedInput`, so zclaude always sends the input back
(with the answers, or the edited plan).

## Known limits

- zclaude relies on Claude Code internals that are not a documented API: the hook
  decision schema beyond the documented fields, the transcript format, the TUI's
  wording (the permission-mode footer and the plan card's choices are read off the
  screen), the config keys that skip start-up modals, and the in-process hooks in
  `agent.js` (`ReadableStream.getReader`, `JSON.stringify`, `process.stdin.push`).
  A Claude Code update can change any of these. Everything degrades rather than
  breaks: without the agent, prompts go through `keys` and the `hook` transport and
  there are no token streams; unknown screens can still be read and answered with
  `screen` and `keys`. To find undocumented behavior, run `strings -n 8` on the
  resolved `claude` binary (a Bun single executable) and grep.
- Some of what zclaude reports is read off the screen because Claude Code shows it
  nowhere else: the permission mode, the plan card's choices, other cards, API
  retries and the /tasks view. Claude Code's API calls don't pass through the
  agent's hooks in this version, so rate-limit headers aren't reported; a rate
  limit that ends a turn comes as `turn.end` with `status: "error"`.
- `effort.set` saves the level as the default for new sessions, as `/effort` does.
- A plan approved with feedback gets it as the next prompt, not on the approval
  itself (a hook can't attach it). The card's "clear context" and Ultraplan choices
  start new conversations, which a hook can't ask for: pick them on the card with
  `{option: N}` once the dialog is no longer held, or with `keys`.
- Run on Linux x86_64; built (not run) for macOS arm64. Other Unixes need the constants in
  `zclaude/src/sys.odin` checked. Windows is not supported.

## License

MIT. See [LICENSE](LICENSE).
