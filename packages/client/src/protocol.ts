// zclaude's wire protocol: JSON-RPC 2.0, one JSON object per line, over the stdio of
// `zclaude --stdio` or the session's Unix socket. Requests carry an `id`. Events are
// notifications whose method is the event type and whose params start with `seq`.
//
// zclaude keeps no history. Everything a consumer wants to keep, it stores itself;
// `store.ts` has an optional in-memory reducer for UIs.

export type SessionState = 'starting' | 'idle' | 'busy' | 'awaiting_input' | 'ended' | 'exited';

export type PermissionMode = 'default' | 'acceptEdits' | 'plan' | 'auto' | 'dontAsk' | 'bypassPermissions';

export interface Meta {
  session_id: string;
  transcript_path: string;
  cwd: string;
  model: string;
  /** A model switch sent and not yet confirmed. */
  model_pending: string;
  model_error: string;
  code_mode: boolean;
  permission_mode: PermissionMode | '';
  /** The in-process agent that streams tokens and types prompts. */
  agent_connected: boolean;
  hook_waiter_armed: boolean;
  /** The model's effort level, from Claude Code's hooks: low | medium | high | xhigh | max. */
  effort: EffortLevel | '';
  /**
   * Tokens in the main conversation's context as of its last message (input +
   * cache reads + cache writes + output). Compare with the model's context window.
   */
  context_tokens: number;
  /** The session's cost so far in USD, live from Claude Code's status line; null until it reports. */
  cost_usd: number | null;
  /** The context window as Claude Code reports it: its size and how much is used. */
  context: { window_tokens?: number; used_percentage?: number; input_tokens?: number; output_tokens?: number } | null;
  /**
   * The plan's usage limits as Claude Code reports them, e.g.
   * `{ five_hour: { used_percentage, resets_at }, seven_day: {…}, spend_limit?: {…} }`
   * (`resets_at` in Unix seconds). Null for accounts without them.
   */
  rate_limits: Record<string, { used_percentage?: number; resets_at?: number; [key: string]: unknown }> | null;
  thinking: boolean;
  fast_mode: boolean;
  /**
   * Which of zclaude's sources are live: Claude Code's hooks, the agent inside its
   * process, its status line, and its transcript (created with the first message).
   */
  sources: { hooks: boolean; agent: boolean; status_line: boolean; transcript: boolean };
}

export type EffortLevel = 'low' | 'medium' | 'high' | 'xhigh' | 'max';

export interface Usage {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_creation_input_tokens: number;
}

/**
 * What the session is doing right now:
 * - `starting`, `idle`, `exited`
 * - `requesting`: a model call is on its way, no tokens yet
 * - `thinking`, `responding`: tokens are arriving
 * - `calling`: the model is writing a tool call (`tool` names it)
 * - `tool`: a tool is running (`tool`)
 * - `retrying`: an API call failed and Claude Code retries at `retry_at`
 * - `compacting`
 * - `waiting`: a dialog needs an answer
 */
export type ActivityKind = 'starting' | 'idle' | 'requesting' | 'thinking' | 'responding' | 'calling' | 'tool' | 'retrying' | 'compacting' | 'waiting' | 'exited';

export interface Activity {
  activity: ActivityKind;
  tool?: string;
  /** When this activity began (Unix ms). */
  since: number;
  /** `retrying`: when the next attempt goes out (Unix ms). */
  retry_at?: number;
}

/** A background task, as Claude Code reports them with every Stop. */
export interface BackgroundTask {
  id: string;
  /** shell | subagent | monitor | workflow | … */
  type: string;
  status: string;
  description: string;
  command?: string;
  agent_type?: string;
  server?: string;
  tool?: string;
  name?: string;
}

export interface AgentInfo {
  agent_id: string;
  agent_type: string;
  /** The Agent/Task tool call that started it. */
  parent_tool_use_id?: string;
  /** Claude Code's own helpers (prompt suggestions, memory), which have no agent type. */
  internal: boolean;
}

/**
 * `terminal` is a selection card on the terminal that no hook describes (a model
 * picker, a card whose hook has gone, anything new): its `input` is
 * `{ text, options }`, read off the screen, and it is answered by choice number.
 */
export type DialogKind = 'question' | 'permission' | 'plan' | 'elicitation' | 'terminal';

/** Modes a plan can be approved into. */
export type PlanMode = Exclude<PermissionMode, 'plan'>;

export interface DialogInfo {
  id: string;
  kind: DialogKind;
  /** The tool asking, e.g. Bash, AskUserQuestion, ExitPlanMode. Empty for elicitation and terminal. */
  tool: string;
  /**
   * The tool input. For elicitation: { server, message, mode?, url?, requested_schema? }.
   * For terminal: { text: the card as shown, options: its choice labels }.
   */
  input: any;
  /** Rules the terminal would offer to "always allow" (permission_suggestions). */
  suggestions: any[];
  status: 'open';
  created_at: number;
  /** zclaude still holds the decision. False once the terminal took it over. */
  held: boolean;
  /** Someone pressed keys in the terminal while it was open. */
  touched: boolean;
  /**
   * Plan dialogs: the approve choices the terminal card offers, in its order, e.g.
   * ['auto', 'default']. Empty until the card is drawn; a `dialog.update` fills it.
   */
  modes?: PlanMode[];
}

/** Statuses a dialog can end in. */
export type DialogStatus =
  | 'open'
  | 'answered' | 'cancelled' // question
  | 'allowed' | 'denied' // permission
  | 'approved' | 'rejected' // plan
  | 'accepted' | 'declined' // elicitation (also 'cancelled')
  | 'closed'; // terminal: the card went away by itself (also 'answered', 'cancelled')

/** Changes to an open dialog, or how it closed. Only the fields that changed are set. */
export interface DialogUpdate {
  id: string;
  status: DialogStatus;
  /** Who closed it. Absent when a turn or session ending closed it. */
  resolved_by?: 'rpc' | 'terminal';
  /** Questions: each question's text mapped to the answer Claude received. */
  answers?: Record<string, string>;
  held?: boolean;
  touched?: boolean;
  modes?: PlanMode[];
}

export interface PromptInfo {
  id: string;
  text: string;
  transport: 'inproc' | 'hook';
  status: 'queued' | 'delivered' | 'received' | 'failed';
}

export interface LiveBlock {
  index: number;
  type: string;
  name: string;
  text: string;
  started_at: number;
  ended_at?: number;
}

export interface LiveStream {
  stream: number;
  message_id: string;
  model: string;
  main: boolean;
  status: 'streaming' | 'done' | 'aborted';
  started_at: number;
  usage: Usage;
  blocks: LiveBlock[];
}

export interface Snapshot {
  protocol: number;
  seq: number;
  pid: number;
  mode: 'stdio' | 'interactive';
  socket: string;
  state: SessionState;
  meta: Meta;
  dialogs: DialogInfo[];
  prompts: PromptInfo[];
  streams: LiveStream[];
  term: { cols: number; rows: number };
  activity: Activity;
  /** The turn in progress, if any. */
  turn: { turn: number; claude_prompt_id?: string; started_at: number } | null;
  tasks: BackgroundTask[];
  /** Subagents running now. */
  agents: AgentInfo[];
}

export interface Entry {
  uuid: string;
  session_id: string;
  role: 'user' | 'assistant' | 'system';
  /** terminal | external | notification | tool_result | command | meta | interrupt | system | assistant */
  origin: string;
  timestamp: string;
  text: string;
  blocks: any[];
  model?: string;
  message_id?: string;
  prompt_id?: string;
  sidechain: boolean;
  /** A subagent's entry: the agent, and the tool call that started it. */
  agent_id?: string;
  parent_tool_use_id?: string;
  /** User lines: Claude Code's id for the prompt they belong to (as on `turn.*` and hooks). */
  claude_prompt_id?: string;
  /** Assistant lines: the query that made the request, e.g. repl_main_thread or agent:builtin:Explore. */
  query_source?: string;
  /** Replayed from before this subscriber or this process. */
  historic?: boolean;
}

/** How a turn ended. Every `entry` of the turn comes before it. */
export interface TurnEnd {
  turn: number;
  /** done, interrupted (Esc or an interrupt), error (StopFailure), or exited. */
  status: 'done' | 'interrupted' | 'error' | 'exited';
  /** The last main-conversation message's: end_turn, max_tokens, refusal, … */
  stop_reason?: string;
  /** Claude Code's id for the prompt that started the turn. */
  claude_prompt_id?: string;
  /** zclaude prompts the turn took in. */
  prompt_ids: string[];
  started_at: number;
  ended_at: number;
  /** Claude Code's own measure when the transcript has it. */
  duration_ms: number;
  /** Main-conversation model calls in the turn. */
  messages: number;
  usage: Usage;
  /** What the turn cost in USD, by Claude Code's own count. */
  cost_usd?: number;
  /** StopFailure: the error kind (rate_limit, …) and details. */
  error?: string;
  error_details?: string;
  last_message?: string;
}

/** Event params by method. Every params object also has `seq`. */
export interface EventMap {
  ready: { snapshot: Snapshot };
  state: { state: SessionState; previous: SessionState };
  meta: Partial<Meta>;
  hook: { name: string; tool?: string; tool_use_id?: string; agent_id?: string; agent_type?: string; source?: string; notification_type?: string; message?: string };
  prompt: PromptInfo & { error?: string };
  entry: Entry;
  'stream.start': { stream: number; message_id: string; model: string; main: boolean; in_thread: boolean; previous_message_id?: string; in_transcript: boolean; started_at: number; usage: Usage };
  /** The running output count (and the input side) of a model call. */
  'stream.usage': { stream: number; usage: Usage };
  'stream.block': { stream: number; index: number; type: string; name?: string; started_at: number };
  'stream.delta': { stream: number; index: number; text: string };
  'stream.block_stop': { stream: number; index: number; ended_at: number };
  'stream.stop_reason': { stream: number; stop_reason: string };
  'stream.end': { stream: number; status: 'done' | 'aborted'; ended_at: number };
  /** The transcript holds this message; `main` and `query_source` settle which conversation it was. */
  'stream.confirmed': { stream: number; message_id: string; main?: boolean; query_source?: string };
  'dialog.open': DialogInfo;
  'dialog.update': DialogUpdate;
  'term.output': { data: string; redraw?: boolean };
  'term.resize': { cols: number; rows: number };
  /** Claude's exit code; 128 + n when signal n ended it, which `signal` names. */
  exit: { code: number; signal?: string };
  'turn.start': { turn: number; claude_prompt_id?: string; started_at: number };
  'turn.end': TurnEnd;
  activity: Activity;
  /** Claude Code is retrying a failed API call (read off its screen). */
  'api.retry': { status?: number; error?: string; attempt?: number; max_attempts?: number; retry_in_ms: number };
  'agent.start': AgentInfo;
  'agent.stop': AgentInfo & { last_message?: string };
  tasks: { tasks: BackgroundTask[] };
}

export type EventType = keyof EventMap;

export type ZEvent = { [K in EventType]: { method: K; params: EventMap[K] & { seq: number } } }[EventType];

export interface QuestionAnswer {
  /** Option labels. One for a single-select question. */
  selected?: string[];
  /** Free text, like the terminal's "Type something" field. */
  other?: string;
  /** Notes on the selection, which Claude reads with the answer. */
  notes?: string;
}

/** Answers or declines an AskUserQuestion dialog. */
export type QuestionResponse =
  | { answers: QuestionAnswer[] | Record<string, string>; /** A free reply to the questions as a whole. */ response?: string }
  | { response: string }
  | { decision: 'cancel'; message?: string; interrupt?: boolean };

/** Decides a tool permission dialog. */
export type PermissionResponse =
  | {
      decision: 'allow' | 'allow_always';
      /** Run the tool with this input instead. */
      updated_input?: Record<string, unknown>;
      /** Rules to add; `allow_always` without these uses the dialog's `suggestions`. */
      updated_permissions?: unknown[];
      /** Also switch the permission mode, like the card's "Yes, and switch to auto mode". */
      mode?: PermissionMode;
    }
  /** `message` reaches Claude as the terminal's "tell Claude what to do differently". */
  | { decision: 'deny'; message?: string; interrupt?: boolean };

/** Decides an ExitPlanMode dialog, like the terminal card's choices. */
export type PlanResponse =
  | {
      decision: 'approve';
      /** Defaults to the card's first choice (`modes[0]`), as Enter would pick. */
      mode?: PlanMode;
      /** An edited plan, carried out instead of Claude's. */
      plan?: string;
      /**
       * Feedback with the approval, given on the card as a person does (its "Tell
       * Claude what to change" field, then Shift+Tab), so it approves into the card's
       * first choice. The result's status is `sent`; `dialog.update` confirms.
       */
      message?: string;
    }
  /** "Tell Claude what to change": Claude keeps planning. `interrupt` also ends the turn. */
  | { decision: 'reject'; message?: string; interrupt?: boolean };

/** Answers an MCP server's elicitation. */
export type ElicitationResponse = { action: 'accept' | 'decline' | 'cancel'; content?: Record<string, unknown> };

/**
 * Picks a choice on the card on screen, the way a person would: arrows to it, `text`
 * into its field if it has one, then Enter. Cancel is Esc. Works for `terminal`
 * dialogs, and for any dialog that is no longer `held`.
 */
export type CardResponse = { option: number; text?: string } | { decision: 'cancel' };

export interface DialogResponses {
  question: QuestionResponse | CardResponse;
  permission: PermissionResponse | CardResponse;
  plan: PlanResponse | CardResponse;
  elicitation: ElicitationResponse | CardResponse;
  terminal: CardResponse;
}

/** The responses a dialog of kind `K` takes. */
export type DialogResponseFor<K extends DialogKind> = DialogResponses[K];

export type DialogResponse = DialogResponses[DialogKind];

export interface DialogResult {
  dialog_id: string;
  /** How it closed; `sent` when a choice was picked on the card of a dialog no longer held. */
  status: DialogStatus | 'sent';
  /** The mode switched to (plans, or permissions allowed with `mode`). */
  mode?: PermissionMode;
}

export type Key =
  | 'enter' | 'esc' | 'tab' | 'shift+tab' | 'up' | 'down' | 'left' | 'right' | 'home' | 'end'
  | 'pageup' | 'pagedown' | 'backspace' | 'delete' | 'space' | 'shift+enter'
  | `ctrl+${string}` | `alt+${string}`;

export interface ScreenInfo {
  cols: number;
  rows: number;
  cursor: { x: number; y: number; visible: boolean };
  alt_screen: boolean;
  bracketed_paste: boolean;
  lines: string[];
  permission_mode?: PermissionMode;
  ansi?: string;
}

/** Methods a consumer can call, with their params and results. */
export interface Methods {
  status: [Record<string, never> | undefined, Snapshot];
  subscribe: [{ term?: boolean; history?: boolean } | undefined, Snapshot];
  unsubscribe: [undefined, true];
  /**
   * `images` attach like a file dropped on the terminal: a path, or base64 `data`
   * (written to a private file for the session's lifetime). inproc only.
   */
  'prompt.send': [
    { text: string; transport?: 'inproc' | 'hook'; images?: Array<{ path: string } | { data: string; media_type?: 'image/png' | 'image/jpeg' | 'image/gif' | 'image/webp' }> },
    { prompt_id: string; status: string; transport: string },
  ];
  command: [{ text: string }, { prompt_id: string; status: string }];
  interrupt: [undefined, { sent: boolean; via?: 'esc' | 'dialog'; state?: SessionState }];
  'dialog.respond': [{ id: string } & DialogResponse, DialogResult];
  'model.set': [{ model: string }, { model: string; status: 'switching' }];
  /**
   * For this session, through the /model picker (←/→, then `s`), as a person does.
   * `save` uses `/effort LEVEL` instead, which also makes it the default for new
   * sessions.
   */
  'effort.set': [{ level: EffortLevel; save?: boolean }, { effort: EffortLevel; status: 'set' | 'switching' }];
  /** Stops a background task through /tasks, as a person would. */
  'task.stop': [{ id: string }, { task_id: string; stopped: true }];
  'mode.set': [{ mode: PermissionMode }, { mode: PermissionMode }];
  keys: [{ keys?: Array<Key | { text: string } | { key: Key }>; text?: string; data?: string; delay_ms?: number }, true];
  'term.write': [{ data?: string; text?: string }, true];
  'term.resize': [{ cols: number; rows: number }, true];
  screen: [{ ansi?: boolean } | undefined, ScreenInfo];
  memory: [undefined, any];
  /**
   * Ends the session: stops the turn, refuses open dialogs and types /exit, then
   * SIGHUP after 6 s and SIGKILL 4 s later. `force` (or calling again) skips ahead.
   * Wait for the `exit` event.
   */
  shutdown: [{ force?: boolean } | undefined, { stopping: 'graceful' | 'hangup' | 'kill' | 'exited' }];
}

export type Method = keyof Methods;
