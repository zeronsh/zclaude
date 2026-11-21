// What each tool call means for display. Pure, so it can be tested without a browser.

export interface ToolBlock {
  id: string;
  name: string;
  input?: Record<string, any>;
}

export interface ToolResult {
  content?: string | Array<{ type?: string; text?: string }>;
  is_error?: boolean;
}

export type ToolKind = 'shell' | 'code' | 'read' | 'edit' | 'write' | 'search' | 'web' | 'agent' | 'plan' | 'mcp' | 'tool';

export interface ToolInfo {
  kind: ToolKind;
  active: string;
  done: string;
  target: string;
  mono?: boolean;
  chip?: string;
}

export interface DiffRow {
  type: 'add' | 'del' | 'same' | 'hunk' | 'file';
  text: string;
}

export const stripAnsi = (text: string): string => text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '');

/** Codex wraps commands in `/bin/zsh -lc '...'`, which is only noise to a reader. */
export function unwrapShell(command: unknown): string {
  const text = String(command ?? '');
  const match = text.match(/^\S*(?:ba|z)?sh\s+-l?c\s+(['"])([\s\S]*)\1$/);
  return match ? match[2]!.replace(/'\\''/g, "'") : text;
}

export function shortenPath(path: unknown): string {
  const parts = String(path ?? '').split('/').filter(Boolean);
  return parts.length > 3 ? `…/${parts.slice(-3).join('/')}` : String(path ?? '');
}

const LANGUAGES: Record<string, string> = {
  rs: 'rust', js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
  py: 'python', go: 'go', rb: 'ruby', java: 'java', c: 'c', h: 'c', cpp: 'cpp', css: 'css', html: 'html', json: 'json',
  md: 'markdown', sh: 'bash', zsh: 'bash', yml: 'yaml', yaml: 'yaml', toml: 'toml', sql: 'sql', swift: 'swift', kt: 'kotlin',
};

export const languageOf = (path: unknown): string => LANGUAGES[String(path ?? '').split('.').pop()?.toLowerCase() ?? ''] ?? '';

export function resultText(result: ToolResult | undefined): string {
  if (!result) return '';
  const { content } = result;
  if (typeof content === 'string') return stripAnsi(content);
  return stripAnsi((content ?? []).map((part) => part.text ?? `[${part.type}]`).join('\n'));
}

export function planItems(input: Record<string, any> | undefined): Array<Record<string, any>> {
  const items = input?.todos ?? input?.plan;
  return Array.isArray(items) ? items : [];
}

function planSummary(input: Record<string, any> | undefined): string {
  const items = planItems(input);
  if (!items.length) return '';
  const done = items.filter((item) => item.status === 'completed').length;
  return `${done} of ${items.length} done`;
}

export function describeTool(block: ToolBlock): ToolInfo {
  const input = block.input ?? {};
  const name = block.name ?? 'Tool';
  if (name.startsWith('mcp__')) {
    const [, server, ...tool] = name.split('__');
    return { kind: 'mcp', active: 'Calling', done: 'Called', target: tool.join('__'), mono: true, chip: server };
  }
  switch (name) {
    case 'Bash':
    case 'Shell':
    case 'shell':
    case 'exec_command':
      return { kind: 'shell', active: 'Running', done: 'Ran', target: unwrapShell(input.command), mono: true };
    case 'REPL':
    case 'Eval': {
      const code = typeof input.code === 'string' ? input.code : '';
      const lines = code ? code.split('\n') : [];
      const firstLine = lines.find((line) => line.trim())?.trim() ?? '';
      const hasDesc = typeof input.description === 'string' && input.description.trim().length > 0;
      return {
        kind: 'code',
        active: 'Running code',
        done: 'Ran code',
        target: hasDesc ? input.description.trim() : firstLine,
        mono: !hasDesc,
        chip: lines.length ? `${lines.length} ${lines.length === 1 ? 'line' : 'lines'}` : undefined,
      };
    }
    case 'Read':
    case 'NotebookRead':
      return { kind: 'read', active: 'Reading', done: 'Read', target: shortenPath(input.file_path), mono: true };
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
    case 'apply_patch':
      return { kind: 'edit', active: 'Editing', done: 'Edited', target: shortenPath(input.file_path ?? input.notebook_path), mono: true };
    case 'Write':
      return { kind: 'write', active: 'Writing', done: 'Wrote', target: shortenPath(input.file_path), mono: true };
    case 'Grep':
      return { kind: 'search', active: 'Searching', done: 'Searched', target: String(input.pattern ?? ''), mono: true, chip: input.glob ?? input.type };
    case 'Glob':
      return { kind: 'search', active: 'Finding', done: 'Found', target: String(input.pattern ?? ''), mono: true };
    case 'WebSearch':
    case 'webSearch':
      return { kind: 'web', active: 'Searching the web', done: 'Searched the web', target: String(input.query ?? '') };
    case 'WebFetch':
      return { kind: 'web', active: 'Fetching', done: 'Fetched', target: String(input.url ?? ''), mono: true };
    case 'Task':
    case 'Agent':
    case 'collabAgentToolCall':
      return { kind: 'agent', active: 'Delegating', done: 'Delegated', target: String(input.description ?? input.prompt ?? ''), chip: input.subagent_type };
    case 'TodoWrite':
    case 'update_plan':
      return { kind: 'plan', active: 'Updating plan', done: 'Updated plan', target: planSummary(input) };
    default:
      return { kind: 'tool', active: name, done: name, target: String(input.description ?? input.command ?? input.file_path ?? input.pattern ?? '') };
  }
}

/** Line diff by longest common subsequence, trimmed at both ends first. */
export function lineDiff(before: string, after: string): DiffRow[] {
  const a = before.length ? before.split('\n') : [];
  const b = after.length ? after.split('\n') : [];
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--;
    endB--;
  }
  const rows: DiffRow[] = a.slice(Math.max(0, start - 2), start).map((text) => ({ type: 'same', text }));
  const midA = a.slice(start, endA);
  const midB = b.slice(start, endB);
  if (midA.length * midB.length > 250000) {
    rows.push(...midA.map((text): DiffRow => ({ type: 'del', text })), ...midB.map((text): DiffRow => ({ type: 'add', text })));
  } else {
    const table = Array.from({ length: midA.length + 1 }, () => new Uint32Array(midB.length + 1));
    for (let i = midA.length - 1; i >= 0; i--) {
      for (let j = midB.length - 1; j >= 0; j--) {
        table[i]![j] = midA[i] === midB[j] ? table[i + 1]![j + 1]! + 1 : Math.max(table[i + 1]![j]!, table[i]![j + 1]!);
      }
    }
    let i = 0;
    let j = 0;
    while (i < midA.length || j < midB.length) {
      if (i < midA.length && j < midB.length && midA[i] === midB[j]) {
        rows.push({ type: 'same', text: midA[i]! });
        i++;
        j++;
      } else if (j < midB.length && (i === midA.length || table[i]![j + 1]! >= table[i + 1]![j]!)) {
        rows.push({ type: 'add', text: midB[j++]! });
      } else {
        rows.push({ type: 'del', text: midA[i++]! });
      }
    }
  }
  rows.push(...a.slice(endA, endA + 2).map((text): DiffRow => ({ type: 'same', text })));
  return rows;
}

export function unifiedDiff(diff: unknown): DiffRow[] {
  const rows: DiffRow[] = [];
  for (const line of String(diff ?? '').split('\n')) {
    if (/^(\+\+\+|---|diff |index )/.test(line)) continue;
    if (line.startsWith('@@')) rows.push({ type: 'hunk', text: line });
    else if (line.startsWith('+')) rows.push({ type: 'add', text: line.slice(1) });
    else if (line.startsWith('-')) rows.push({ type: 'del', text: line.slice(1) });
    else if (line) rows.push({ type: 'same', text: line.replace(/^ /, '') });
  }
  return rows;
}

export function diffRows(block: ToolBlock): DiffRow[] {
  const input = block.input ?? {};
  if (Array.isArray(input.changes)) {
    return input.changes.flatMap((change: Record<string, any>): DiffRow[] => [
      { type: 'file', text: String(change.path ?? '') },
      ...unifiedDiff(change.diff),
    ]);
  }
  if (block.name === 'Write') {
    return String(input.content ?? '').split('\n').map((text): DiffRow => ({ type: 'add', text }));
  }
  if (Array.isArray(input.edits)) {
    return input.edits.flatMap((edit: Record<string, any>, i: number): DiffRow[] => [
      ...(i ? [{ type: 'hunk', text: '⋯' } as DiffRow] : []),
      ...lineDiff(edit.old_string ?? '', edit.new_string ?? ''),
    ]);
  }
  return lineDiff(String(input.old_string ?? ''), String(input.new_string ?? ''));
}

export function diffStat(block: ToolBlock): { add: number; del: number } | null {
  const rows = diffRows(block);
  const add = rows.filter((row) => row.type === 'add').length;
  const del = rows.filter((row) => row.type === 'del').length;
  return add || del ? { add, del } : null;
}

/** Claude Code prefixes file contents with `   12→`. Returns the bare file text. */
export function fileText(result: ToolResult | undefined): string {
  const lines = resultText(result).split('\n');
  const numbered = lines.filter(Boolean).length > 0 && lines.filter(Boolean).every((line) => /^\s*\d+[→\t]/.test(line));
  if (!numbered) return lines.join('\n');
  return lines.filter(Boolean).map((line) => line.replace(/^\s*\d+[→\t]/, '')).join('\n');
}

export function resultSummary(info: ToolInfo, result: ToolResult | undefined): string {
  if (!result || result.is_error) return '';
  const text = resultText(result);
  const count = text.split('\n').filter(Boolean).length;
  if (info.kind === 'read') return `${count} ${count === 1 ? 'line' : 'lines'}`;
  if (info.kind === 'search' && !/^no (matches|files)/i.test(text)) return `${count} ${count === 1 ? 'result' : 'results'}`;
  return '';
}

export function isDenied(result: ToolResult | undefined): boolean {
  return /doesn't want to proceed|^\(?declined\)?$|rejected/i.test(resultText(result).trim());
}

export function formatDuration(ms: number): string {
  if (!(ms >= 0)) return '';
  if (ms < 1000) return `${Math.max(Math.round(ms), 1)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s`;
}

const pluralize = (count: number, noun: string): string => `${count} ${noun}${count === 1 ? '' : 's'}`;

export interface GroupItem {
  block?: ToolBlock;
  result?: ToolResult;
  waiting?: boolean;
  name?: string;
}

/** "Ran 2 commands · read 1 file", or whatever is happening right now. */
export function toolGroupLabel(items: GroupItem[]): string {
  if (items.some((item) => item.waiting)) return 'Needs approval';
  const preparing = items.find((item) => !item.block);
  const running = items.find((item) => item.block && !item.result);
  if (running?.block) {
    const info = describeTool(running.block);
    const target = info.target.split('\n')[0] ?? '';
    return `${info.active}${target ? ` ${target.length > 60 ? `${target.slice(0, 60)}…` : target}` : ''}`;
  }
  if (preparing) return `Preparing ${preparing.name ?? 'tool'}`;
  const counts = new Map<ToolKind, number>();
  for (const item of items) {
    if (!item.block) continue;
    const { kind } = describeTool(item.block);
    counts.set(kind, (counts.get(kind) ?? 0) + 1);
  }
  const phrase = (kind: ToolKind, count: number): string => {
    switch (kind) {
      case 'shell':
        return `Ran ${pluralize(count, 'command')}`;
      case 'code':
        return `Ran ${pluralize(count, 'script')}`;
      case 'read':
        return `Read ${pluralize(count, 'file')}`;
      case 'edit':
        return `Edited ${pluralize(count, 'file')}`;
      case 'write':
        return `Wrote ${pluralize(count, 'file')}`;
      case 'search':
        return `Searched ${count === 1 ? 'once' : `${count} times`}`;
      case 'web':
        return `Used the web ${count === 1 ? 'once' : `${count} times`}`;
      case 'agent':
        return `Delegated ${pluralize(count, 'task')}`;
      case 'plan':
        return 'Updated the plan';
      default:
        return `Used ${pluralize(count, 'tool')}`;
    }
  };
  const parts = [...counts].map(([kind, count]) => phrase(kind, count));
  const label = parts.map((part, i) => (i ? part.charAt(0).toLowerCase() + part.slice(1) : part)).join(' · ');
  const failed = items.filter((item) => item.result?.is_error).length;
  return failed ? `${label} · ${failed} failed` : label;
}
