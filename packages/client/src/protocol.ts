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
}

export type DialogKind = 'question' | 'permission' | 'plan' | 'elicitation';

export interface DialogInfo {
  id: string;
  kind: DialogKind;
  /** The tool asking, e.g. Bash, AskUserQuestion, ExitPlanMode. Empty for elicitation. */
  tool: string;
  /** The tool input. For elicitation: { server, message, mode?, url?, requested_schema? }. */
  input: any;
  /** Rules the terminal would offer to "always allow" (permission_suggestions). */
  suggestions: any[];
  status: 'open';
  created_at: number;
  /** zclaude still holds the decision. False once the terminal took it over. */
  held: boolean;
  /** Someone pressed keys in the terminal while it was open. */
  touched: boolean;
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
  /** Replayed from before this subscriber or this process. */
  historic?: boolean;
}

/** Event params by method. Every params object also has `seq`. */
export interface EventMap {
  ready: { snapshot: Snapshot };
  state: { state: SessionState; previous: SessionState };
  meta: Partial<Meta>;
  hook: { name: string; tool?: string; tool_use_id?: string; agent_id?: string; agent_type?: string; source?: string; notification_type?: string; message?: string };
  prompt: PromptInfo & { error?: string };
  entry: Entry;
  'stream.start': { stream: number; message_id: string; model: string; main: boolean; in_thread: boolean; previous_message_id?: string; in_transcript: boolean; started_at: number };
  'stream.block': { stream: number; index: number; type: string; name?: string; started_at: number };
  'stream.delta': { stream: number; index: number; text: string };
  'stream.block_stop': { stream: number; index: number; ended_at: number };
  'stream.stop_reason': { stream: number; stop_reason: string };
  'stream.end': { stream: number; status: 'done' | 'aborted'; ended_at: number };
  'stream.confirmed': { stream: number; message_id: string };
  'dialog.open': DialogInfo;
  'dialog.update': { id: string; status: string; resolved_by?: 'rpc' | 'terminal'; answers?: Record<string, string>; held?: boolean; touched?: boolean };
  'term.output': { data: string; redraw?: boolean };
  'term.resize': { cols: number; rows: number };
  exit: { code: number };
}

export type EventType = keyof EventMap;

export type ZEvent = { [K in EventType]: { method: K; params: EventMap[K] & { seq: number } } }[EventType];

export interface QuestionAnswer {
  /** Option labels. One for a single-select question. */
  selected?: string[];
  /** Free text, like the terminal's "Type something" field. */
  other?: string;
}

export type DialogResponse =
  | { decision: 'allow' | 'allow_always'; updated_input?: Record<string, unknown>; updated_permissions?: unknown[] }
  | { decision: 'deny'; message?: string; interrupt?: boolean }
  | { answers: QuestionAnswer[] | Record<string, string> }
  | { decision: 'cancel'; message?: string }
  | { decision: 'approve'; mode?: Exclude<PermissionMode, 'plan'> }
  | { decision: 'reject'; message?: string }
  | { action: 'accept' | 'decline' | 'cancel'; content?: Record<string, unknown> };

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
  'prompt.send': [{ text: string; transport?: 'inproc' | 'hook' }, { prompt_id: string; status: string; transport: string }];
  command: [{ text: string }, { prompt_id: string; status: string }];
  interrupt: [undefined, { sent: boolean; via?: 'esc' | 'dialog'; state?: SessionState }];
  'dialog.respond': [{ id: string } & DialogResponse, { dialog_id: string; status: string }];
  'model.set': [{ model: string }, { model: string; status: 'switching' }];
  'mode.set': [{ mode: PermissionMode }, { mode: PermissionMode }];
  keys: [{ keys?: Array<Key | { text: string } | { key: Key }>; text?: string; data?: string; delay_ms?: number }, true];
  'term.write': [{ data?: string; text?: string }, true];
  'term.resize': [{ cols: number; rows: number }, true];
  screen: [{ ansi?: boolean } | undefined, ScreenInfo];
  memory: [undefined, any];
  shutdown: [undefined, true];
}

export type Method = keyof Methods;
