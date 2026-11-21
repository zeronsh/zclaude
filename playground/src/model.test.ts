import { test } from 'bun:test';
import assert from 'node:assert/strict';
import type { DialogView } from '@zclaude/client/store';
import { buildRows, newMemo, rowsToText, type Entry, type Row, type Stream, type Value } from './model.ts';
import { describeTool, diffRows, diffStat, fileText, formatDuration, isDenied, lineDiff, toolGroupLabel, unifiedDiff, unwrapShell } from './tools.ts';

const NOW = 1_000_000;

const entry = (uuid: string, role: string, origin: string, blocks: unknown[], extra: Partial<Entry> = {}): Entry => ({
  uuid,
  session_id: 's',
  role: role as Entry['role'],
  origin,
  timestamp: String(NOW),
  text: '',
  blocks,
  sidechain: false,
  ...extra,
});

const dialog = (id: string, kind: DialogView['kind'], status: DialogView['status'], extra: Partial<DialogView> = {}): DialogView => ({
  id,
  kind,
  tool: kind === 'question' ? 'AskUserQuestion' : 'Bash',
  input: {},
  suggestions: [],
  status,
  created_at: 1,
  held: true,
  touched: false,
  ...extra,
});

type BlockIn = Omit<Stream['blocks'][number], 'index' | 'text'> & { index?: number; text?: string };
const stream = (message_id: string, blocks: BlockIn[], extra: Partial<Stream> = {}): Stream => ({
  message_id,
  main: true,
  status: 'streaming',
  started_at: NOW - 5000,
  blocks: blocks.map((block, index) => ({ index, text: '', ...block })),
  ...extra,
});

const kinds = (rows: Row[]) => rows.map((row) => row.kind);
const build = (value: Value, memo = newMemo()) => buildRows(value, NOW, memo);

test('a live text block and its transcript entry share one row key', () => {
  const memo = newMemo();
  const live = build({ streams: { s1: stream('m1', [{ type: 'text', text: 'Hel' }]) } }, memo).rows;
  assert.equal(live.length, 1);
  assert.equal(live[0]!.key, 'm1:text:0');
  assert.equal((live[0] as any).live, true);
  const final = build(
    {
      entries: [entry('e1', 'assistant', 'assistant', [{ type: 'text', text: 'Hello' }], { message_id: 'm1' })],
      streams: { s1: stream('m1', [{ type: 'text', text: 'Hello' }], { status: 'done', in_transcript: true, ended_at: NOW }) },
    },
    memo,
  ).rows;
  assert.equal(final.length, 1, 'not drawn twice');
  assert.equal(final[0]!.key, 'm1:text:0');
  assert.equal((final[0] as any).live, false);
});

test('blocks the transcript holds are not repeated by a stream still running', () => {
  const rows = build({
    entries: [entry('e1', 'assistant', 'assistant', [{ type: 'thinking', thinking: 'plan' }], { message_id: 'm1' })],
    streams: {
      s1: stream('m1', [{ type: 'thinking', text: 'plan' }, { type: 'text', text: 'answer' }], { in_transcript: true }),
    },
  }).rows;
  assert.deepEqual(kinds(rows), ['thought', 'text']);
});

test('background calls never show, however long they run', () => {
  const title = stream('m1', [{ type: 'text', text: '{"title":"x"}' }], { main: false, started_at: NOW - 60000 });
  assert.equal(build({ streams: { s1: title } }).rows.length, 0);
  const classifier = stream('m2', [{ type: 'text', text: 'allow' }], { main: false, status: 'done', ended_at: NOW });
  assert.equal(build({ streams: { s1: classifier } }).rows.length, 0);
});

test('a misjudged main stream still appears once the transcript confirms it', () => {
  const rows = build({ streams: { s1: stream('m1', [{ type: 'text', text: 'hi' }], { main: false, in_transcript: true }) } }).rows;
  assert.deepEqual(kinds(rows), ['text']);
});

test('a reply that happens to be JSON streams like any other, and unknown block types never render', () => {
  const json = stream('m1', [{ type: 'text', text: '{"answer":1}' }]);
  assert.equal(build({ streams: { s1: json } }).rows.length, 1);
  const server = stream('m2', [{ type: 'server_tool_use', text: '{"query":"x"}' }]);
  assert.equal(build({ streams: { s1: server } }).rows.length, 0);
});

test('a finished main stream waits briefly for its transcript line, then goes', () => {
  const soon = stream('m1', [{ type: 'text', text: 'hi' }], { status: 'done', ended_at: NOW - 100 });
  const pending = build({ streams: { s1: soon } });
  assert.equal(pending.rows.length, 1);
  assert.equal(pending.recheckIn, 1400);
  const late = stream('m1', [{ type: 'text', text: 'hi' }], { status: 'done', ended_at: NOW - 5000 });
  assert.equal(build({ streams: { s1: late } }).rows.length, 0);
});

test('an interrupted stream keeps its text and says so', () => {
  const rows = build({ streams: { s1: stream('m1', [{ type: 'text', text: 'partial' }], { status: 'aborted' }) } }).rows;
  assert.equal((rows[0] as any).aborted, true);
  assert.equal((rows[0] as any).live, false);
});

const toolsIn = (rows: Row[]) => rows.flatMap((row) => (row.kind === 'tools' ? row.tools : [])) as any[];

test('tool results attach to their call, and open dialogs mark it waiting', () => {
  const value: Value = {
    entries: [
      entry('e1', 'assistant', 'assistant', [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls' } }], { message_id: 'm1' }),
      entry('e2', 'user', 'tool_result', [{ type: 'tool_result', tool_use_id: 't1', content: 'a.txt' }], { timestamp: String(NOW + 1500) }),
      entry('e3', 'assistant', 'assistant', [{ type: 'tool_use', id: 't2', name: 'Bash', input: { command: 'rm' } }], { message_id: 'm2' }),
    ],
    dialogs: { t2: dialog('t2', 'permission', 'open') },
  };
  const tools = toolsIn(build(value).rows);
  assert.equal(tools.length, 2);
  assert.equal(tools[0].finishedAt - tools[0].startedAt, 1500);
  assert.equal(tools[0].waiting, false);
  assert.equal(tools[1].waiting, true);
});

test('consecutive tools fold into one group that keeps its key as it grows', () => {
  const user = entry('e0', 'user', 'terminal', [], { text: 'go' });
  const use = (id: string) => entry(`u-${id}`, 'assistant', 'assistant', [{ type: 'tool_use', id, name: 'Read', input: {} }], { message_id: id });
  const one = build({ entries: [user, use('t1')] }).rows;
  const two = build({ entries: [user, use('t1'), use('t2')] }).rows;
  assert.deepEqual(kinds(two), ['user', 'tools']);
  assert.equal(one[1]!.key, two[1]!.key);
  assert.equal(toolsIn(two).length, 2);
  const split = build({ entries: [user, use('t1'), entry('e2', 'assistant', 'assistant', [{ type: 'text', text: 'hm' }]), use('t2')] }).rows;
  assert.deepEqual(kinds(split), ['user', 'tools', 'text', 'tools']);
});

test('a tool being prepared joins the group, with no raw input shown', () => {
  const rows = build({ streams: { s1: stream('m1', [{ type: 'tool_use', name: 'Edit', text: '{"file_path":"/x"}' }]) } }).rows;
  assert.deepEqual(kinds(rows), ['tools']);
  assert.equal(toolsIn(rows)[0].kind, 'preparing');
  assert.equal(rowsToText(rows), '');
});

test('a running turn reports it is working, without adding a row', () => {
  const user = entry('e0', 'user', 'terminal', [], { text: 'go' });
  assert.equal(build({ state: 'busy', entries: [user] }).working, true);
  assert.equal(build({ state: 'idle', entries: [user] }).working, false);
  const streaming = build({ state: 'busy', entries: [user], streams: { s1: stream('m1', [{ type: 'text', text: 'hi' }]) } });
  assert.equal(streaming.working, true);
  assert.deepEqual(kinds(streaming.rows), ['user', 'text']);
  const thinking = build({ state: 'busy', entries: [user], streams: { s1: stream('m1', [{ type: 'thinking', text: 'hm' }]) } });
  assert.equal(thinking.working, false, 'a thought has its own label');
});

test('a tool being prepared stays until the transcript takes over, so its group never blinks out', () => {
  const blocks = [{ type: 'tool_use', name: 'Bash' }];
  const finished = (status: Stream['status'], extra = {}) => build({ streams: { s1: { ...stream('m1', blocks), status, ended_at: NOW, ...extra } } }).rows;
  assert.equal(toolsIn(finished('done'))[0].kind, 'preparing');
  assert.deepEqual(finished('aborted'), [], 'an interrupted one will never arrive');
  assert.deepEqual(finished('done', { ended_at: NOW - 60_000 }), [], 'nor will one the transcript never recorded');
});

test('questions hide while open and become a record when answered', () => {
  const ask = entry('e1', 'assistant', 'assistant', [
    { type: 'tool_use', id: 'q1', name: 'AskUserQuestion', input: { questions: [{ question: 'Color?' }] } },
  ]);
  const open = build({ entries: [ask], dialogs: { q1: dialog('q1', 'question', 'open') } });
  assert.equal(open.rows.length, 0);
  const done = build({
    entries: [ask],
    dialogs: { q1: dialog('q1', 'question', 'answered', { answers: { 'Color?': 'Green' } }) },
  });
  assert.equal(rowsToText(done.rows), 'Color? → Green');
  const declined = build({ entries: [ask], dialogs: { q1: dialog('q1', 'question', 'cancelled') } });
  assert.equal(rowsToText(declined.rows), 'Question declined');
});

test('a question from an earlier session falls back to the tool summary', () => {
  const rows = build({
    entries: [
      entry('e1', 'assistant', 'assistant', [{ type: 'tool_use', id: 'q1', name: 'AskUserQuestion', input: { questions: [] } }]),
      entry('e2', 'user', 'tool_result', [{ type: 'tool_result', tool_use_id: 'q1', content: 'answered: Green' }]),
    ],
  }).rows;
  assert.equal(rowsToText(rows), 'answered: Green');
});

test('user rows show their source, and pending prompts appear until received', () => {
  const rows = build({
    entries: [
      entry('e1', 'user', 'terminal', [], { text: 'typed' }),
      entry('e2', 'user', 'external', [], { text: 'sent', prompt_id: 'p1' }),
      entry('e3', 'user', 'meta', [], { text: 'hidden' }),
    ],
    prompts: {
      p1: { id: 'p1', text: 'sent', transport: 'inproc', status: 'received' },
      p2: { id: 'p2', text: 'waiting', transport: 'api', status: 'delivered' },
    },
  }).rows;
  assert.equal(rows.length, 3);
  assert.match(rowsToText(rows), /typed\ntyped in terminal\nsent\nfrom chat · in-process\nwaiting\ndelivered/);
});

test('unchanged rows keep their identity, including tool groups', () => {
  const memo = newMemo();
  const value: Value = {
    entries: [
      entry('e1', 'user', 'terminal', [], { text: 'hi' }),
      entry('e2', 'assistant', 'assistant', [{ type: 'tool_use', id: 't1', name: 'Read', input: {} }]),
    ],
  };
  const first = build(value, memo).rows;
  const second = build(value, memo).rows;
  assert.equal(second[0], first[0]);
  assert.equal(second[1], first[1]);
});

test('group labels summarize finished work and name what is running', () => {
  const tool = (name: string, input: object, result?: object) => ({ block: { id: name, name, input }, result });
  assert.equal(toolGroupLabel([tool('Bash', { command: 'ls' }, {}), tool('Bash', { command: 'pwd' }, {}), tool('Read', {}, {})]), 'Ran 2 commands · read 1 file');
  assert.equal(toolGroupLabel([tool('Bash', { command: 'cargo test' })]), 'Running cargo test');
  assert.equal(toolGroupLabel([{ ...tool('Bash', { command: 'rm' }), waiting: true }]), 'Needs approval');
  assert.equal(toolGroupLabel([{ name: 'Edit' }]), 'Preparing Edit');
  assert.equal(toolGroupLabel([tool('Bash', {}, { is_error: true })]), 'Ran 1 command · 1 failed');
});

test('thinking shows how long it took, from its own block when it can', () => {
  const rows = build({
    entries: [entry('e1', 'assistant', 'assistant', [{ type: 'thinking', thinking: 'hm' }], { message_id: 'm1' })],
    streams: {
      s1: stream('m1', [{ type: 'thinking', text: 'hm', started_at: 100, ended_at: 2200 }], { status: 'done', in_transcript: true, ended_at: 9000 }),
    },
  }).rows;
  assert.equal((rows[0] as any).duration, 2100);
});

test('a duration reported with the thinking itself wins over stream timing', () => {
  const rows = build({
    entries: [entry('e1', 'assistant', 'assistant', [{ type: 'thinking', thinking: 'hm', duration_ms: 1800 }], { message_id: 'r1' })],
    streams: { s1: stream('r1', [{ type: 'thinking', text: 'hm' }], { status: 'done', in_transcript: true, started_at: 100, ended_at: 102 }) },
  }).rows;
  assert.equal((rows[0] as any).duration, 1800);
});

test('tools are described by what they did', () => {
  assert.equal(describeTool({ id: '', name: 'Bash', input: { command: 'ls' } }).done, 'Ran');
  assert.equal(describeTool({ id: '', name: 'Read', input: { file_path: '/a/b/c/d/e.rs' } }).target, '…/c/d/e.rs');
  const mcp = describeTool({ id: '', name: 'mcp__linear__get_issue' });
  assert.deepEqual([mcp.kind, mcp.chip, mcp.target], ['mcp', 'linear', 'get_issue']);
  assert.equal(describeTool({ id: '', name: 'TodoWrite', input: { todos: [{ status: 'completed' }, { status: 'pending' }] } }).target, '1 of 2 done');
});

test('shell wrappers come off Codex commands, and only those', () => {
  assert.equal(unwrapShell(`/bin/zsh -lc 'touch a.txt'`), 'touch a.txt');
  assert.equal(unwrapShell(`bash -c "echo hi"`), 'echo hi');
  assert.equal(unwrapShell(`/bin/zsh -lc 'echo '\\''x'\\'''`), `echo 'x'`);
  assert.equal(unwrapShell('cargo test -- -c x'), 'cargo test -- -c x');
});

test('line diffs show changes with context', () => {
  const rows = lineDiff('a\nb\nc\nd\ne', 'a\nb\nX\nd\ne');
  assert.deepEqual(rows.map((r) => `${r.type}:${r.text}`), ['same:a', 'same:b', 'add:X', 'del:c', 'same:d', 'same:e']);
  assert.deepEqual(diffStat({ id: '', name: 'Edit', input: { old_string: 'a\nb', new_string: 'a\nc\nd' } }), { add: 2, del: 1 });
});

test('Write is all additions, and unified diffs parse without their headers', () => {
  assert.deepEqual(diffStat({ id: '', name: 'Write', input: { content: 'x\ny' } }), { add: 2, del: 0 });
  const rows = unifiedDiff('--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same');
  assert.deepEqual(rows.map((r) => r.type), ['hunk', 'del', 'add', 'same']);
  const codex = diffRows({ id: '', name: 'Edit', input: { changes: [{ path: 'x.rs', diff: '+new' }] } });
  assert.deepEqual(codex.map((r) => r.type), ['file', 'add']);
});

test('line numbers come off file views only when every line has one', () => {
  assert.equal(fileText({ content: '     1→fn main() {\n     2→}\n' }), 'fn main() {\n}');
  assert.equal(fileText({ content: '1→ok\nnot numbered' }), '1→ok\nnot numbered');
});

test('denied calls are told apart from failed ones', () => {
  assert.equal(isDenied({ content: "The user doesn't want to proceed with this tool use.", is_error: true }), true);
  assert.equal(isDenied({ content: '(declined)', is_error: true }), true);
  assert.equal(isDenied({ content: 'Exit code 1', is_error: true }), false);
});

test('durations read naturally', () => {
  assert.equal(formatDuration(240), '240ms');
  assert.equal(formatDuration(2100), '2.1s');
  assert.equal(formatDuration(65000), '1m 5s');
  assert.equal(formatDuration(NaN), '');
});

test('Code Mode REPL and Eval tools describe scripts and group cleanly', () => {
  const withDesc = describeTool({ id: 'r1', name: 'REPL', input: { description: 'Count lines', code: 'const a = 1;\nconsole.log(a);' } });
  assert.deepEqual([withDesc.kind, withDesc.active, withDesc.done, withDesc.target, withDesc.mono, withDesc.chip], [
    'code',
    'Running code',
    'Ran code',
    'Count lines',
    false,
    '2 lines',
  ]);
  const noDesc = describeTool({ id: 'r2', name: 'Eval', input: { code: '\nconst x = 42;' } });
  assert.deepEqual([noDesc.kind, noDesc.target, noDesc.mono, noDesc.chip], ['code', 'const x = 42;', true, '2 lines']);

  assert.equal(toolGroupLabel([{ block: { id: 'r1', name: 'REPL', input: { code: '1' } }, result: {} }]), 'Ran 1 script');
  const preparing = build({ streams: { s1: stream('m1', [{ type: 'tool_use', name: 'REPL' }]) } }).rows;
  assert.equal(toolsIn(preparing)[0].name, 'Code');
});

test('slash command args and model switch confirmations render as concise notes', () => {
  const rows = build({
    entries: [
      entry('e1', 'user', 'command', [], {
        text: '<command-name>/model</command-name>\n<command-args>haiku</command-args>',
      }),
      entry('e2', 'user', 'command', [], {
        text: '<local-command-stdout>\x1b[32mSet model to `Haiku 5.5` and saved as your default\x1b[0m</local-command-stdout>',
      }),
      entry('e3', 'user', 'command', [], {
        text: '<local-command-stdout>unrelated output</local-command-stdout>',
      }),
    ],
  }).rows;
  assert.deepEqual(
    rows.map((r) => (r.kind === 'note' ? r.text : '')),
    ['/model haiku', 'Set model to Haiku 5.5 and saved as your default'],
  );
});

test('a question answered from the terminal or here is recorded from the dialog answers', () => {
  const ask = entry('e1', 'assistant', 'assistant', [
    { type: 'tool_use', id: 'q1', name: 'AskUserQuestion', input: { questions: [{ question: 'Pet?' }, { question: 'Food?' }] } },
  ]);
  const rows = build({ entries: [ask], dialogs: { q1: dialog('q1', 'question', 'answered', { answers: { 'Pet?': 'Cat', 'Food?': 'Pizza, own' }, resolved_by: 'rpc' }) } }).rows;
  assert.equal(rowsToText(rows), 'Pet? → Cat\nFood? → Pizza, own');
});

test('a held permission marks its tool waiting until it closes', () => {
  const use = entry('e1', 'assistant', 'assistant', [{ type: 'tool_use', id: 'b1', name: 'Bash', input: { command: 'touch x' } }]);
  assert.equal(toolsIn(build({ entries: [use], dialogs: { b1: dialog('b1', 'permission', 'open') } }).rows)[0].waiting, true);
  assert.equal(toolsIn(build({ entries: [use], dialogs: { b1: dialog('b1', 'permission', 'allowed') } }).rows)[0].waiting, false);
});

test('streams order by their number, not by when their key was added', () => {
  const rows = build({
    streams: {
      s10: stream('m10', [{ type: 'text', text: 'second' }]),
      s9: stream('m9', [{ type: 'text', text: 'first' }]),
    },
  }).rows;
  assert.equal(rowsToText(rows), 'first\nsecond');
});
