// The conversation's rows, built from Mugen primitives so every height is computed
// rather than measured. Mugen calls each row as a plain function, which is why mugen
// hooks are called directly here and React effects aren't used.
import { Collapse, Escape, HStack, Text, VStack, definePrimitive, textHeight, useMugenState, useMugenTween, type MugenInstance } from '@wingleeio/mugen';
import { Markdown, type DeepPartial, type MarkdownTheme } from '@wingleeio/mugen-markdown';
import {
  Bot,
  ChevronRight,
  Code,
  FilePen,
  FilePlus,
  FileText,
  Globe,
  ListTodo,
  Plug,
  Search,
  SquareTerminal,
  Wrench,
  type LucideIcon,
} from 'lucide-react';
import type { ReactNode } from 'react';
import { cn } from './lib/utils.ts';
import { originLabel, type Row, type ToolItem } from './model.ts';
import {
  describeTool,
  diffRows,
  diffStat,
  fileText,
  formatDuration,
  isDenied,
  languageOf,
  planItems,
  resultSummary,
  resultText,
  toolGroupLabel,
  unwrapShell,
  type ToolBlock,
  type ToolInfo,
  type ToolResult,
} from './tools.ts';

export const SANS_FAMILY = "'Geist Variable'";
export const MONO_FAMILY = "'Geist Mono Variable'";
const SANS = `${SANS_FAMILY}, sans-serif`;
const MONO = `${MONO_FAMILY}, monospace`;
const LABEL = `500 12px ${MONO}` as const;
const CODE = `12.5px ${MONO}` as const;
const SMALL = `12px ${SANS}` as const;

/** Fonts every row is measured with. They must be loaded before the first row. */
export const ROW_FONTS = [`400 15px ${SANS_FAMILY}`, `500 12px ${SANS_FAMILY}`, `600 15px ${SANS_FAMILY}`, `400 13px ${MONO_FAMILY}`, `500 12px ${MONO_FAMILY}`];

const INK = {
  fg: 'var(--foreground)',
  muted: 'var(--muted-foreground)',
  red: 'var(--destructive)',
  amber: 'var(--warning)',
  hairline: 'var(--border)',
  wash: 'var(--muted)',
} as const;

const MAX_OUTPUT_LINES = 60;
const MAX_DIFF_LINES = 240;
const MAX_FILE_LINES = 300;

const CHAT_THEME: DeepPartial<MarkdownTheme> = {
  fontFamily: SANS_FAMILY,
  monoFamily: MONO,
  fontSize: 15,
  lineHeight: 26,
  color: INK.fg,
  blockGap: 14,
  heading: { color: INK.fg, weight: 600 },
  link: { color: INK.fg, underline: true },
  inlineCode: { background: INK.wash, color: INK.fg, sizeScale: 0.9 },
  code: {
    background: INK.wash,
    color: INK.fg,
    padding: 14,
    radius: 8,
    fontSize: 13,
    lineHeight: 21,
    header: {
      show: true,
      height: 36,
      fontSize: 12,
      background: INK.wash,
      color: INK.muted,
      borderColor: INK.hairline,
      buttonBackground: 'var(--background)',
    },
  },
  blockquote: { borderColor: INK.hairline, color: INK.muted, padding: 12, gap: 8, borderWidth: 2 },
  list: { gap: 8, indent: 22, markerColor: INK.muted },
  table: { borderColor: INK.hairline, headerBackground: INK.wash, minColumnWidth: 110 },
  rule: { color: INK.hairline },
};

export const REASONING_THEME: DeepPartial<MarkdownTheme> = {
  fontFamily: SANS_FAMILY,
  monoFamily: MONO,
  fontSize: 14,
  lineHeight: 24,
  color: INK.muted,
  blockGap: 10,
  heading: { color: INK.muted, weight: 600 },
  link: { color: INK.fg, underline: true },
  inlineCode: { background: INK.wash, color: INK.muted, sizeScale: 0.9 },
  code: { background: INK.wash, color: INK.muted, padding: 12, radius: 8, fontSize: 12.5, lineHeight: 19 },
  blockquote: { borderColor: INK.hairline, color: INK.muted, padding: 10, gap: 8, borderWidth: 2 },
  list: { gap: 6, indent: 20, markerColor: INK.muted },
};

/** Clickable disclosure header, a real <button>. */
const Disclosure = definePrimitive('button', { name: 'Disclosure' });

const buttonReset = {
  cursor: 'pointer',
  textAlign: 'left',
  background: 'transparent',
  border: 'none',
  font: 'inherit',
  color: 'inherit',
  borderRadius: 6,
} as const;

// Collapse pins its column's height mid-tween. Shrinkable children would squash and
// then pop to natural size on the last frame, instead of clipping.
const NO_SHRINK = { flexShrink: 0 } as const;

const Space = ({ height }: { height: number }): ReactNode => <VStack height={height} />;

function firstLines(text: string, limit: number): { text: string; hidden: number } {
  const lines = text.split('\n');
  if (lines.length <= limit) return { text, hidden: 0 };
  return { text: lines.slice(0, limit).join('\n'), hidden: lines.length - limit };
}

/** A fence that a code sample can't close early. */
function fenced(code: string, language: string): string {
  const longest = Math.max(2, ...[...code.matchAll(/`+/g)].map((match) => match[0].length));
  const fence = '`'.repeat(longest + 1);
  return `${fence}${language}\n${code}\n${fence}`;
}

// ---------- User ----------

type UserItem = Extract<Row, { kind: 'user' }>;

const USER_FONT = `15px ${SANS}` as const;
const USER_LINE_HEIGHT = 24;
const USER_COLLAPSED_TEXT = 3 * USER_LINE_HEIGHT;
const BUBBLE_PADDING = 14;
/** Everything in a user row but its text: spaces, bubble padding, label and gaps. */
const USER_CHROME = 12 + 2 * BUBBLE_PADDING + 16 + 10 + 3 * 6;

function userTextHeight(item: UserItem, width: number): number {
  return textHeight(item.text, USER_FONT, width - 2 * BUBBLE_PADDING, USER_LINE_HEIGHT, { whiteSpace: 'pre-wrap' });
}

/** A user row's height with its text collapsed, whether or not it's expanded now. */
export function collapsedUserHeight(item: UserItem, width: number): number {
  return USER_CHROME + Math.min(userTextHeight(item, width), USER_COLLAPSED_TEXT);
}

function UserRow(item: UserItem, list: MugenInstance<Row>): ReactNode {
  const [expanded, setExpanded] = useMugenState(false);
  const natural = userTextHeight(item, list.contentWidth());
  const long = natural > USER_COLLAPSED_TEXT;
  const textBox = useMugenTween(long && expanded ? natural : Math.min(natural, USER_COLLAPSED_TEXT), { duration: 220 });
  const toggle = (): void => {
    // Read it from the top: following the bottom would push its start off screen.
    if (!expanded) list.stickInterrupt?.();
    setExpanded(!expanded);
  };
  const text = (
    <Text shrink whiteSpace="pre-wrap" font={USER_FONT} lineHeight={USER_LINE_HEIGHT} color="var(--secondary-foreground)">
      {item.text}
    </Text>
  );
  const failed = item.status === 'failed';
  const label = item.status
    ? failed
      ? `Not delivered: ${item.error ?? 'request failed'}`
      : item.status === 'queued'
        ? 'Queued'
        : 'Sending…'
    : originLabel(item.origin, item.transport);
  return (
    <VStack gap={6} className={cn('user-row', item.status && 'pending')}>
      <Space height={12} />
      <HStack justify="flex-end">
        <VStack padding={BUBBLE_PADDING} style={{ background: 'var(--secondary)', borderRadius: 'calc(var(--radius) + 4px)' }}>
          {long ? (
            <VStack height={textBox} className={expanded ? 'user-text' : 'user-text clamped'} style={NO_SHRINK}>
              {text}
            </VStack>
          ) : (
            text
          )}
        </VStack>
      </HStack>
      <HStack justify="flex-end" gap={10}>
        {long ? (
          <Disclosure className="user-toggle" aria-expanded={expanded} onClick={toggle} style={buttonReset}>
            <Text font={SMALL} lineHeight={16} color={INK.muted}>
              {expanded ? 'Show less' : 'Show more'}
            </Text>
          </Disclosure>
        ) : null}
        <Text shrink font={SMALL} lineHeight={16} color={failed ? INK.red : INK.muted}>
          {label}
        </Text>
      </HStack>
      <Space height={10} />
    </VStack>
  );
}

// ---------- Assistant ----------

export function Caret(): ReactNode {
  return (
    <Text font={`600 15px ${SANS}`} lineHeight={26} color={INK.fg} className="caret">
      ▍
    </Text>
  );
}

function TextRow(item: Extract<Row, { kind: 'text' }>): ReactNode {
  return (
    <VStack>
      <Space height={7} />
      <VStack>
        <Markdown source={item.text} theme={CHAT_THEME} fade={item.live} />
      </VStack>
      {item.aborted ? (
        <VStack>
          <Space height={6} />
          <Text font={SMALL} lineHeight={16} color={INK.muted}>
            Stream interrupted
          </Text>
        </VStack>
      ) : null}
      <Space height={7} />
    </VStack>
  );
}

function ThoughtRow(item: Extract<Row, { kind: 'thought' }>): ReactNode {
  // Only a click changes the height, as with tool groups. It streams in if opened.
  const [open, setOpen] = useMugenState(false);
  const label = item.live ? 'Thinking…' : item.duration && item.duration >= 100 ? `Thought for ${formatDuration(item.duration)}` : 'Thought';
  return (
    <VStack>
      <Space height={7} />
      <Disclosure padding={2} className="disclosure" aria-expanded={open} onClick={() => setOpen(!open)} style={buttonReset}>
        <Text font={LABEL} lineHeight={16} color={INK.muted} className={item.live ? 'shimmer' : undefined}>
          {label}
        </Text>
      </Disclosure>
      <Collapse id="thought" open={open} duration={220}>
        <VStack style={NO_SHRINK}>
          <Space height={10} />
          <HStack gap={13} align="stretch">
            <VStack width={2} style={{ background: INK.hairline, borderRadius: 2 }} />
            <VStack>
              <Markdown source={item.text} theme={REASONING_THEME} fade={item.live} />
            </VStack>
          </HStack>
        </VStack>
      </Collapse>
      <Space height={7} />
    </VStack>
  );
}

// ---------- Tools ----------

const KIND_ICONS: Record<ToolInfo['kind'], LucideIcon> = {
  shell: SquareTerminal,
  code: Code,
  read: FileText,
  edit: FilePen,
  write: FilePlus,
  search: Search,
  web: Globe,
  agent: Bot,
  plan: ListTodo,
  mcp: Plug,
  tool: Wrench,
};

function Output({ text, error }: { text: string; error?: boolean }): ReactNode {
  const shown = firstLines(text, MAX_OUTPUT_LINES);
  return (
    <VStack padding={12} gap={6} className="tool-panel">
      <Text font={CODE} lineHeight={20} whiteSpace="pre-wrap" color={error ? INK.red : INK.muted}>
        {shown.text}
      </Text>
      {shown.hidden ? (
        <Text font={SMALL} lineHeight={16} color={INK.muted}>
          {`${shown.hidden} more lines in the terminal`}
        </Text>
      ) : null}
    </VStack>
  );
}

function ShellView({ block, result }: { block: ToolBlock; result?: ToolResult }): ReactNode {
  const command = unwrapShell(block.input?.command);
  const output = resultText(result).replace(/\n+$/, '');
  const quiet = /^\(?(no output|completed|.* completed with no output)\)?$/i.test(output.trim());
  const shown = firstLines(output, MAX_OUTPUT_LINES);
  return (
    <VStack className="tool-panel">
      <HStack gap={8} padding={12}>
        <Text shrink font={CODE} lineHeight={20} color={INK.muted}>
          $
        </Text>
        <Text font={CODE} lineHeight={20} whiteSpace="pre-wrap" color={INK.fg}>
          {command}
        </Text>
      </HStack>
      {result && output && !quiet ? (
        <VStack padding={12} gap={6} className="console-output">
          <Text font={CODE} lineHeight={20} whiteSpace="pre-wrap" color={result.is_error ? INK.red : INK.muted}>
            {shown.text}
          </Text>
          {shown.hidden ? (
            <Text font={SMALL} lineHeight={16} color={INK.muted}>
              {`${shown.hidden} more lines in the terminal`}
            </Text>
          ) : null}
        </VStack>
      ) : null}
    </VStack>
  );
}

function DiffView({ block }: { block: ToolBlock }): ReactNode {
  const rows = diffRows(block);
  const shown = rows.slice(0, MAX_DIFF_LINES);
  const signs = { add: '+', del: '−', same: ' ' } as const;
  return (
    <VStack className="tool-panel">
      <Space height={6} />
      {shown.map((row, i) => {
        if (row.type === 'file' || row.type === 'hunk') {
          return (
            <HStack key={i} padding={6} className={`diff-${row.type}`}>
              <Text font={`11.5px ${MONO}`} lineHeight={16} color={INK.muted}>
                {row.text}
              </Text>
            </HStack>
          );
        }
        return (
          <HStack key={i} className={`diff-row ${row.type}`}>
            <VStack width={24} align="center">
              <Text shrink font={CODE} lineHeight={20} className="sign">
                {signs[row.type]}
              </Text>
            </VStack>
            <Text font={CODE} lineHeight={20} whiteSpace="pre-wrap">
              {row.text || ' '}
            </Text>
          </HStack>
        );
      })}
      {rows.length > shown.length ? (
        <HStack padding={6}>
          <Text font={SMALL} lineHeight={16} color={INK.muted}>
            {`${rows.length - shown.length} more lines`}
          </Text>
        </HStack>
      ) : null}
      <Space height={6} />
    </VStack>
  );
}

function PlanView({ block }: { block: ToolBlock }): ReactNode {
  return (
    <VStack gap={8} padding={12} className="tool-panel">
      {planItems(block.input).map((item, i) => {
        const status = String(item.status ?? 'pending');
        const text = String((status === 'in_progress' ? item.activeForm : null) ?? item.content ?? item.step ?? '');
        return (
          <HStack key={i} gap={9} align="flex-start" className={`plan-item ${status}`}>
            <Escape width={16} height={20}>
              <span className="plan-mark" />
            </Escape>
            <Text font={`13.5px ${SANS}`} lineHeight={20} color={status === 'completed' ? INK.muted : INK.fg}>
              {text}
            </Text>
          </HStack>
        );
      })}
    </VStack>
  );
}

function CodeView({ block, result }: { block: ToolBlock; result?: ToolResult }): ReactNode {
  const source = typeof block.input?.code === 'string' ? block.input.code.replace(/\n+$/, '') : '';
  const shown = firstLines(source, MAX_FILE_LINES);
  const output = resultText(result).replace(/\n+$/, '');
  const quiet = /^\(?(no output|completed|.* completed with no output)\)?$/i.test(output.trim());
  return (
    <VStack gap={8}>
      {source ? (
        <VStack gap={4}>
          <Markdown source={fenced(shown.text, 'javascript')} theme={CHAT_THEME} />
          {shown.hidden ? (
            <Text font={SMALL} lineHeight={16} color={INK.muted}>
              {`${shown.hidden} more lines in the terminal`}
            </Text>
          ) : null}
        </VStack>
      ) : null}
      {result && output && !quiet ? <Output text={output} error={result.is_error} /> : null}
    </VStack>
  );
}

function ToolBody({ block, info, result }: { block: ToolBlock; info: ToolInfo; result?: ToolResult }): ReactNode {
  switch (info.kind) {
    case 'shell':
      return <ShellView block={block} result={result} />;
    case 'code':
      return <CodeView block={block} result={result} />;
    case 'edit':
    case 'write':
      return (
        <VStack gap={6}>
          <DiffView block={block} />
          {result?.is_error ? <Output text={resultText(result)} error /> : null}
        </VStack>
      );
    case 'read': {
      if (!result) return null;
      if (result.is_error) return <Output text={resultText(result)} error />;
      const code = firstLines(fileText(result).replace(/\n+$/, ''), MAX_FILE_LINES);
      return <Markdown source={fenced(code.text, languageOf(block.input?.file_path))} theme={CHAT_THEME} />;
    }
    case 'plan':
      return <PlanView block={block} />;
    case 'agent':
      return (
        <VStack gap={8}>
          {block.input?.prompt ? <Markdown source={String(block.input.prompt)} theme={REASONING_THEME} /> : null}
          {result ? <Output text={resultText(result)} error={result.is_error} /> : null}
        </VStack>
      );
    case 'search':
    case 'web':
      return result ? <Output text={resultText(result)} error={result.is_error} /> : null;
    default:
      return (
        <VStack gap={8}>
          <Output text={JSON.stringify(block.input ?? {}, null, 2)} />
          {result ? <Output text={resultText(result)} error={result.is_error} /> : null}
        </VStack>
      );
  }
}

const CARD = 'flex h-9 w-full min-w-0 items-center gap-2 rounded-md border bg-muted/40 px-2.5 text-left text-muted-foreground';

/** One line in the group. Plain React in a declared box, so it truncates cleanly. */
function ToolCard({ tool, open, onToggle }: { tool: ToolItem; open: boolean; onToggle: () => void }): ReactNode {
  if (tool.kind === 'preparing') {
    return (
      <div className="flex h-full items-center">
        <div className={CARD}>
          <span className="spinner" />
          <span className="flex-none text-xs font-medium text-foreground/80">Preparing</span>
          <span className="min-w-0 truncate text-xs">{tool.name}</span>
        </div>
      </div>
    );
  }
  const { block, result } = tool;
  const info = describeTool(block);
  const failed = Boolean(result?.is_error);
  const state = tool.waiting ? 'waiting' : failed ? 'error' : result ? 'done' : 'running';
  const label = tool.waiting ? 'Needs approval' : failed ? (isDenied(result) ? 'Denied' : 'Failed') : result ? info.done : info.active;
  const stat = info.kind === 'edit' || info.kind === 'write' ? diffStat(block) : null;
  const summary = resultSummary(info, result);
  const duration = tool.finishedAt && tool.finishedAt - tool.startedAt >= 50 ? formatDuration(tool.finishedAt - tool.startedAt) : '';
  const detail = info.target.split('\n')[0] ?? '';
  const Icon = KIND_ICONS[info.kind];
  const meta = 'flex-none font-mono text-[10.5px] text-muted-foreground/80';
  return (
    <div className="flex h-full items-center">
      <button type="button" className={cn(CARD, 'tool-card cursor-pointer transition-colors hover:bg-muted', state, open && 'open')} aria-expanded={open} onClick={onToggle}>
        {state === 'running' ? <span className="spinner" /> : <Icon className="size-3.5 flex-none" />}
        <span className="tool-label flex-none text-xs font-medium text-foreground/80">{label}</span>
        {detail ? (
          <span className={cn('min-w-0 truncate text-xs', info.mono && 'font-mono')} title={detail}>
            {detail}
          </span>
        ) : null}
        {info.chip ? <span className={meta}>{String(info.chip)}</span> : null}
        {stat?.add ? <span className={cn(meta, 'text-success')}>{`+${stat.add}`}</span> : null}
        {stat?.del ? <span className={cn(meta, 'text-destructive')}>{`−${stat.del}`}</span> : null}
        {summary ? <span className={meta}>{summary}</span> : null}
        {duration ? <span className={meta}>{duration}</span> : null}
        <ChevronRight className="tool-chevron ml-auto size-3 flex-none opacity-60 transition-transform" />
      </button>
    </div>
  );
}

function ToolsRow(item: Extract<Row, { kind: 'tools' }>): ReactNode {
  const [openMap, setOpenMap] = useMugenState<Record<string, boolean>>({});
  const active = item.tools.some((tool) => tool.kind === 'preparing' || !tool.result);
  // Only a click changes the height. Opening and closing by itself as each tool ran
  // would move everything around it, so the label reports the progress instead.
  const open = Boolean(openMap.group);
  const label = toolGroupLabel(item.tools.map((tool) => (tool.kind === 'tool' ? tool : { name: tool.name })));
  const waiting = item.tools.some((tool) => tool.kind === 'tool' && tool.waiting);
  return (
    <VStack>
      <Space height={7} />
      {/* Plain React in a declared box: a long command truncates instead of wrapping. */}
      <Escape height={20}>
        <button
          type="button"
          className="disclosure group-head"
          aria-expanded={open}
          onClick={() => setOpenMap({ ...openMap, group: !open })}
          style={{ font: LABEL, lineHeight: '16px', color: waiting ? INK.amber : INK.muted }}
        >
          <span className={active && !waiting ? 'shimmer' : undefined}>{label}</span>
        </button>
      </Escape>
      <Collapse id="group" open={open} duration={220}>
        <VStack style={NO_SHRINK}>
          <Space height={10} />
          <VStack gap={6}>
            {item.tools.map((tool) => {
              const expanded = Boolean(openMap[tool.key]);
              return (
                <VStack key={tool.key}>
                  <Escape height={36}>
                    <ToolCard tool={tool} open={expanded} onToggle={() => setOpenMap({ ...openMap, [tool.key]: !expanded })} />
                  </Escape>
                  {tool.kind === 'tool' ? (
                    <Collapse id={`tool-${tool.key}`} open={expanded} duration={200}>
                      <VStack style={NO_SHRINK}>
                        <Space height={6} />
                        {expanded ? <ToolBody block={tool.block} info={describeTool(tool.block)} result={tool.result} /> : null}
                        <Space height={2} />
                      </VStack>
                    </Collapse>
                  ) : null}
                </VStack>
              );
            })}
          </VStack>
        </VStack>
      </Collapse>
      <Space height={7} />
    </VStack>
  );
}

// ---------- Records and notes ----------

function RecordRow(item: Extract<Row, { kind: 'record' }>): ReactNode {
  return (
    <VStack>
      <Space height={7} />
      <VStack gap={8} padding={12} className="tool-panel">
        {item.declined ? (
          <Text font={`14px ${SANS}`} lineHeight={20} color={INK.muted}>
            Question declined
          </Text>
        ) : item.lines.length ? (
          item.lines.map(([question, answer], i) => (
            <VStack key={i} gap={2}>
              <Text font={`13px ${SANS}`} lineHeight={18} color={INK.muted}>
                {question}
              </Text>
              <Text font={`500 14px ${SANS}`} lineHeight={20} color={INK.fg}>
                {answer}
              </Text>
            </VStack>
          ))
        ) : (
          <Text font={`14px ${SANS}`} lineHeight={20} color={INK.muted}>
            {item.summary ?? 'Question answered'}
          </Text>
        )}
      </VStack>
      <Space height={7} />
    </VStack>
  );
}

function NoteRow(item: Extract<Row, { kind: 'note' }>): ReactNode {
  return (
    <VStack>
      <Space height={7} />
      <Text font={LABEL} lineHeight={16} color={INK.muted}>
        {item.text}
      </Text>
      <Space height={7} />
    </VStack>
  );
}

/** Each key is always the same kind of row, so its hooks stay in one order. */
export function renderRow(item: Row, list: MugenInstance<Row>): ReactNode {
  switch (item.kind) {
    case 'user':
      return UserRow(item, list);
    case 'text':
      return TextRow(item);
    case 'thought':
      return ThoughtRow(item);
    case 'tools':
      return ToolsRow(item);
    case 'record':
      return RecordRow(item);
    case 'note':
      return NoteRow(item);
  }
}
