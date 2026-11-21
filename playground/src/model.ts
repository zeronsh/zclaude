// Turns the session into the rows the conversation shows. Pure, so it can be tested
// without a browser. A live stream and the transcript entry that replaces it share a
// row key, so a row grows in place and never swaps or jumps.
import type { Entry } from '@zclaude/client/protocol';
import { OPEN_DIALOG, type DialogView, type PromptView, type SessionView, type StreamView } from '@zclaude/client/store';
import { stripAnsi, type ToolBlock, type ToolResult } from './tools.ts';

export type { Entry };
export type Stream = StreamView;
export type Dialog = DialogView;

/** The parts of a session view the rows are built from. */
export interface Value {
  state?: SessionView['state'];
  entries?: Entry[];
  streams?: Record<string, StreamView>;
  prompts?: Record<string, PromptView>;
  dialogs?: Record<string, DialogView>;
}

export type ToolItem =
  | { kind: 'tool'; key: string; block: ToolBlock; result?: ToolResult; startedAt: number; finishedAt?: number; waiting: boolean }
  | { kind: 'preparing'; key: string; name: string };

export type Row = { key: string } & (
  | { kind: 'user'; text: string; origin: string; transport?: string; status?: string; error?: string }
  | { kind: 'text'; text: string; live: boolean; aborted: boolean }
  | { kind: 'thought'; text: string; live: boolean; duration: number | null; startedAt: number | null }
  | { kind: 'tools'; tools: ToolItem[] }
  | { kind: 'record'; lines: Array<[string, string]>; declined: boolean; summary?: string }
  | { kind: 'note'; text: string }
);

export { OPEN_DIALOG };

/** How long a finished main stream stays up while its transcript line arrives. */
const TRANSCRIPT_WAIT_MS = 1500;

const ORIGIN_LABELS: Record<string, string> = {
  terminal: 'typed in terminal',
  external: 'from chat',
  notification: 'background notification',
};
const TRANSPORT_LABELS: Record<string, string> = { inproc: 'in-process', hook: 'hook' };
const DECLINED = new Set(['cancelled', 'declined']);

export const originLabel = (origin: string, transport?: string): string => {
  const label = ORIGIN_LABELS[origin] ?? origin;
  const via = transport ? TRANSPORT_LABELS[transport] : undefined;
  return via ? `${label} · ${via}` : label;
};

export const timestampOf = (entry: Entry): number => {
  const value = Number(entry.timestamp);
  return Number.isFinite(value) && value > 0 ? value : Date.parse(entry.timestamp);
};

/** State kept between builds so unchanged content keeps its identity. */
export interface BuildMemo {
  rows: Map<string, Row>;
}

export const newMemo = (): BuildMemo => ({ rows: new Map() });

function thoughtTiming(streams: StreamView[], messageId: string | undefined): { duration: number | null; startedAt: number | null } {
  const stream = messageId ? streams.find((s) => s.message_id === messageId) : undefined;
  const block = stream?.blocks?.find((b) => b.type === 'thinking');
  const start = block?.started_at ?? stream?.started_at ?? null;
  const end = block?.ended_at ?? stream?.ended_at ?? null;
  return { duration: start && end ? end - start : null, startedAt: start };
}

function sameFields(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => {
    if (key === 'lines') return JSON.stringify(a[key]) === JSON.stringify(b[key]);
    if (key === 'tools') {
      const left = a[key] as unknown as Record<string, unknown>[];
      const right = b[key] as unknown as Record<string, unknown>[];
      return left.length === right.length && left.every((tool, i) => sameFields(tool, right[i]!));
    }
    return a[key] === b[key];
  });
}

const sameRow = (a: Row, b: Row): boolean => sameFields(a as unknown as Record<string, unknown>, b as unknown as Record<string, unknown>);

export interface Build {
  rows: Row[];
  /** Milliseconds until a row's visibility changes with no new data, if any. */
  recheckIn: number | null;
  /** A turn is running, so the caret below the conversation should show. */
  working: boolean;
}

export function buildRows(value: Value, now: number, memo: BuildMemo): Build {
  const flat: Array<Row | ToolItem> = [];
  const streams = Object.entries(value.streams ?? {}).sort(([a], [b]) => Number(a.slice(1)) - Number(b.slice(1)));
  const streamList = streams.map(([, stream]) => stream);
  const dialogs = value.dialogs ?? {};
  const prompts = value.prompts ?? {};
  const counts = new Map<string, Record<string, number>>();
  const tools = new Map<string, Extract<ToolItem, { kind: 'tool' }>>();
  const records = new Map<string, Extract<Row, { kind: 'record' }>>();
  const waiting = new Set<string>();
  for (const [id, dialog] of Object.entries(dialogs)) {
    if (OPEN_DIALOG.has(dialog.status)) waiting.add(id);
  }

  const nextIndex = (messageId: string, type: string): number => {
    const seen = counts.get(messageId) ?? {};
    const index = seen[type] ?? 0;
    seen[type] = index + 1;
    counts.set(messageId, seen);
    return index;
  };

  for (const entry of value.entries ?? []) {
    if (entry.sidechain) continue;
    if (entry.origin === 'interrupt') {
      flat.push({ kind: 'note', key: entry.uuid, text: 'Interrupted' });
      continue;
    }
    if (entry.role === 'system') {
      flat.push({ kind: 'note', key: entry.uuid, text: entry.text || 'Conversation compacted' });
      continue;
    }
    const blocks: any[] = Array.isArray(entry.blocks) ? entry.blocks : [];
    if (entry.origin === 'tool_result') {
      for (const block of blocks) {
        if (block.type !== 'tool_result') continue;
        const tool = tools.get(block.tool_use_id);
        if (tool) {
          tool.result = block;
          tool.finishedAt = timestampOf(entry);
        }
        const record = records.get(block.tool_use_id);
        if (record && !record.lines.length && !record.declined) {
          const content = block.content;
          record.summary = typeof content === 'string' ? content : (content ?? []).map((part: any) => part.text ?? '').join('\n');
        }
      }
      continue;
    }
    if (entry.role === 'user') {
      if (entry.origin === 'command') {
        const command = entry.text.match(/<command-name>([^<]+)<\/command-name>/);
        if (command) {
          const args = entry.text.match(/<command-args>([^<]+)<\/command-args>/)?.[1]?.trim();
          flat.push({ kind: 'note', key: entry.uuid, text: args ? `${command[1]!} ${args}` : command[1]! });
          continue;
        }
        const stdout = entry.text.match(/<local-command-stdout>([\s\S]*?)<\/local-command-stdout>/);
        if (stdout) {
          const clean = stripAnsi(stdout[1]!).replace(/`/g, '').trim();
          const line = clean.split('\n').map((l) => l.trim()).find(Boolean);
          if (line && /^(Set model to|Kept model as|Current model|Model )/i.test(line)) {
            flat.push({ kind: 'note', key: entry.uuid, text: line });
          }
        }
        continue;
      }
      if (!ORIGIN_LABELS[entry.origin]) continue;
      const prompt = entry.prompt_id ? prompts[entry.prompt_id] : undefined;
      flat.push({ kind: 'user', key: entry.uuid, text: entry.text, origin: entry.origin, transport: prompt?.transport });
      continue;
    }
    const messageId = entry.message_id || entry.uuid;
    for (const block of blocks) {
      if (block.type === 'text' && block.text?.trim()) {
        const key = `${messageId}:text:${nextIndex(messageId, 'text')}`;
        flat.push({ kind: 'text', key, text: block.text, live: false, aborted: false });
      } else if (block.type === 'thinking' && block.thinking?.trim()) {
        const key = `${messageId}:thinking:${nextIndex(messageId, 'thinking')}`;
        const timing = thoughtTiming(streamList, entry.message_id);
        flat.push({ kind: 'thought', key, text: block.thinking, live: false, ...timing, duration: block.duration_ms ?? timing.duration });
      } else if (block.type === 'tool_use') {
        nextIndex(messageId, 'tool_use');
        if (block.name === 'AskUserQuestion') {
          const dialog = dialogs[block.id];
          if (dialog && OPEN_DIALOG.has(dialog.status)) continue;
          const answers = dialog?.answers ?? null;
          const record: Extract<Row, { kind: 'record' }> = {
            kind: 'record',
            key: block.id,
            lines: answers ? (block.input?.questions ?? []).map((q: any): [string, string] => [q.question, answers[q.question] ?? '']) : [],
            declined: Boolean(dialog && DECLINED.has(dialog.status)),
          };
          records.set(block.id, record);
          flat.push(record);
          continue;
        }
        const tool: Extract<ToolItem, { kind: 'tool' }> = {
          kind: 'tool',
          key: block.id,
          block,
          startedAt: timestampOf(entry),
          waiting: waiting.has(block.id),
        };
        tools.set(block.id, tool);
        flat.push(tool);
      }
    }
  }

  // Live streams, minus any blocks the transcript already holds. Only the main
  // conversation shows live; zclaude marks it with `main`.
  let recheckIn: number | null = null;
  for (const [streamKey, stream] of streams) {
    const confirmed = Boolean(stream.in_transcript);
    if (!stream.main && !confirmed) continue;
    if (stream.status === 'done') {
      if (confirmed) continue;
      const wait = (stream.ended_at ?? 0) + TRANSCRIPT_WAIT_MS - now;
      if (wait <= 0) continue;
      recheckIn = recheckIn === null ? wait : Math.min(recheckIn, wait);
    }
    const live = stream.status === 'streaming';
    const aborted = stream.status === 'aborted';
    const messageId = stream.message_id || streamKey;
    const seen = counts.get(messageId) ?? {};
    const position: Record<string, number> = {};
    for (const block of stream.blocks ?? []) {
      // Anything else, such as server-side tool input, is not for display.
      if (block.type !== 'text' && block.type !== 'thinking' && block.type !== 'tool_use') continue;
      const index = position[block.type] ?? 0;
      position[block.type] = index + 1;
      if ((seen[block.type] ?? 0) > index) continue;
      if (block.type === 'thinking') {
        if (!block.text?.trim()) continue;
        flat.push({ kind: 'thought', key: `${messageId}:thinking:${index}`, text: block.text, live: live && !block.ended_at, duration: null, startedAt: block.started_at ?? stream.started_at });
      } else if (block.type === 'tool_use') {
        // Stays through the wait for the transcript, or the group would blink out.
        if (block.name === 'AskUserQuestion' || aborted) continue;
        const name =
          block.name === 'REPL' || block.name === 'Eval'
            ? 'Code'
            : block.name?.startsWith('mcp__')
              ? block.name.split('__').slice(2).join('__')
              : (block.name ?? 'tool');
        flat.push({ kind: 'preparing', key: `${messageId}:tool_use:${index}`, name });
      } else if (block.text?.trim()) {
        flat.push({ kind: 'text', key: `${messageId}:text:${index}`, text: block.text, live, aborted });
      }
    }
  }

  // Prompts not yet seen in the conversation.
  for (const [id, prompt] of Object.entries(prompts)) {
    if (prompt.status === 'received') continue;
    flat.push({ kind: 'user', key: `pending:${id}`, text: prompt.text, origin: 'external', transport: prompt.transport, status: prompt.status, error: prompt.error });
  }

  // Consecutive tool calls fold into one group, keyed by the row before it so the
  // group keeps its open state as tools are added.
  const rows: Row[] = [];
  for (const item of flat) {
    if (item.kind === 'tool' || item.kind === 'preparing') {
      const last = rows.at(-1);
      if (last?.kind === 'tools') last.tools.push(item);
      else rows.push({ kind: 'tools', key: `tools-after:${last?.key ?? 'start'}`, tools: [item] });
    } else {
      rows.push(item);
    }
  }

  // A thought has its own "Thinking…" label, so it doesn't need the caret too.
  const last = rows.at(-1);
  const working = value.state === 'busy' && !(last?.kind === 'thought' && last.live);

  // Unchanged rows keep their object, so Mugen and React skip them.
  const stable = rows.map((row) => {
    const previous = memo.rows.get(row.key);
    if (previous && sameRow(previous, row)) return previous;
    memo.rows.set(row.key, row);
    return row;
  });
  return { rows: stable, recheckIn, working };
}

/** The conversation as plain text, including rows scrolled out of the DOM. */
export function rowsToText(rows: Row[]): string {
  const lines: string[] = [];
  for (const row of rows) {
    switch (row.kind) {
      case 'user':
        lines.push(row.text, row.status ? `${row.status}` : originLabel(row.origin, row.transport));
        break;
      case 'text':
        lines.push(row.text);
        break;
      case 'thought':
        lines.push(`Thought: ${row.text}`);
        break;
      case 'tools':
        for (const tool of row.tools) {
          if (tool.kind === 'tool') lines.push(`Tool ${tool.block.name}`);
        }
        break;
      case 'record':
        if (row.declined) lines.push('Question declined');
        else if (row.lines.length) lines.push(...row.lines.map(([q, a]) => `${q} → ${a}`));
        else lines.push(row.summary ?? 'Question answered');
        break;
      case 'note':
        lines.push(row.text);
        break;
    }
  }
  return lines.join('\n');
}
