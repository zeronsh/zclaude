import { MugenVList, VStack, useMugenSelector, useMugenVirtualizer } from '@wingleeio/mugen';
import type { PermissionMode } from '@zclaude/client/protocol';
import type { SessionView } from '@zclaude/client/store';
import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import { ArrowDown, Check, ChevronDown, Code, Copy, RotateCcw, Send, Square, SquareTerminal } from 'lucide-react';
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from 'react';
import { Badge } from './components/ui/badge.tsx';
import { Button } from './components/ui/button.tsx';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from './components/ui/dropdown-menu.tsx';
import { Input } from './components/ui/input.tsx';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './components/ui/select.tsx';
import { Textarea } from './components/ui/textarea.tsx';
import { ToggleGroup, ToggleGroupItem } from './components/ui/toggle-group.tsx';
import { Dock } from './dock.tsx';
import { cn } from './lib/utils.ts';
import { buildRows, newMemo, rowsToText, type Row } from './model.ts';
import { onConnected, onStoreReplaced, onTerminal, remember, rpc, store, stored, toBase64 } from './net.ts';
import { Caret, MONO_FAMILY, SANS_FAMILY, collapsedUserHeight, renderRow } from './rows.tsx';
import { formatDuration } from './tools.ts';

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

// ---------- The session ----------

// Tokens can arrive faster than frames, so the view is read at most once per frame.
let view: SessionView = store.view;
const viewListeners = new Set<() => void>();
let frame = 0;
const publish = () => {
  frame = 0;
  view = store.view;
  for (const listener of viewListeners) listener();
};
const schedule = () => {
  if (!frame) frame = requestAnimationFrame(publish);
};
let unsubscribe = store.subscribe(schedule);
onStoreReplaced(() => {
  unsubscribe();
  unsubscribe = store.subscribe(schedule);
  schedule();
});

const useView = (): SessionView =>
  useSyncExternalStore(
    (listener) => {
      viewListeners.add(listener);
      return () => viewListeners.delete(listener);
    },
    () => view,
  );

// ---------- Terminal ----------

function TerminalPane(): ReactNode {
  const host = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState('');
  useEffect(() => {
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    const term = new Terminal({
      fontFamily: `${MONO_FAMILY}, Menlo, monospace`,
      fontSize: 12.5,
      lineHeight: 1.2,
      scrollback: 20000,
      cursorStyle: 'bar',
      cursorInactiveStyle: 'none',
      theme: dark
        ? { background: '#0a0a0a', foreground: '#fafafa', cursor: '#fafafa', selectionBackground: 'rgba(255,255,255,.2)' }
        : { background: '#ffffff', foreground: '#0a0a0a', cursor: '#0a0a0a', selectionBackground: 'rgba(0,0,0,.15)', black: '#0a0a0a', white: '#737373', brightWhite: '#a3a3a3' },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host.current!);
    const encoder = new TextEncoder();
    const sendSize = () => {
      setSize(`${term.cols}×${term.rows}`);
      rpc('term.resize', { cols: term.cols, rows: term.rows }).catch(() => {});
    };
    term.onData((data) => {
      rpc('term.write', { data: toBase64(encoder.encode(data)) }).catch(() => {});
    });
    term.onResize(sendSize);
    const off = onTerminal((data, redraw) => {
      if (redraw) term.reset();
      term.write(data);
    });
    const observer = new ResizeObserver(() => fit.fit());
    observer.observe(host.current!);
    fit.fit();
    // The size goes out on every connection, and again whenever it changes.
    const offConnected = onConnected(sendSize);
    return () => {
      offConnected();
      off();
      observer.disconnect();
      term.dispose();
    };
  }, []);
  return (
    <main id="terminal" className="flex min-h-0 min-w-0 flex-col">
      <div className="text-muted-foreground flex h-11 flex-none items-center gap-2 border-b px-3 text-xs">
        <SquareTerminal className="size-3.5" />
        <span className="text-foreground font-medium">claude</span>
        <span className="flex-1">the real CLI</span>
        <span className="tabular-nums">{size}</span>
      </div>
      <div id="term" ref={host} className="min-h-0 flex-1 py-2 pr-1 pl-2.5" />
    </main>
  );
}

// ---------- Thread ----------

const THREAD_BOTTOM_SPACE = 56;

function Thread({ rows, working }: { rows: Row[]; working: boolean }): ReactNode {
  const list = useMugenVirtualizer<Row>({ items: rows });
  const pane = useRef<HTMLDivElement>(null);
  const [{ width, height }, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const observer = new ResizeObserver(([entry]) => setSize({ width: entry!.contentRect.width, height: entry!.contentRect.height }));
    observer.observe(pane.current!);
    return () => observer.disconnect();
  }, []);
  const away = useMugenSelector(list, (state) => state.distanceFromBottom > 200);
  // A new prompt means attention is back on the latest turn, wherever the list was
  // left. Otherwise an interrupt or a scroll could leave it behind for good.
  const prompts = rows.filter((row) => row.kind === 'user').length;
  const seenPrompts = useRef(prompts);
  useEffect(() => {
    if (prompts > seenPrompts.current) list.scrollToBottom({ behavior: reducedMotion ? 'auto' : 'smooth' });
    seenPrompts.current = prompts;
  }, [prompts]);
  // The list centres itself at maxW, which is also what gives it side gutters.
  const maxW = Math.max(240, Math.min(768, width - 48));
  const render = useCallback((row: Row) => renderRow(row, list), [list]);
  // The runway: the latest turn fills the view, so its prompt can reach the top with
  // room below for the reply. Mugen measures this after the rows, so it stays exact
  // as they grow.
  const bottomSpace = (): number => {
    const prompt = rows.findLastIndex((row) => row.kind === 'user');
    const row = rows[prompt];
    if (row?.kind !== 'user') return THREAD_BOTTOM_SPACE;
    const reply = list.offsetOf(rows.length) - list.offsetOf(prompt + 1);
    return Math.max(THREAD_BOTTOM_SPACE, height - collapsedUserHeight(row, list.contentWidth()) - reply);
  };
  return (
    <div id="messages" ref={pane} className="relative min-h-0 flex-1">
      {width ? (
        <MugenVList
          instance={list}
          getKey={(row: Row) => row.key}
          render={render}
          font={`15px ${SANS_FAMILY}, sans-serif`}
          lineHeight={26}
          maxW={maxW}
          overscan={320}
          initialScroll="bottom"
          stickToBottom
          renderTop={() => <VStack height={20} />}
          // The caret lives here because it adds no height, so it can't move the conversation.
          renderBottom={() => (
            <VStack height={bottomSpace()}>
              <VStack height={7} />
              {working ? <Caret /> : null}
            </VStack>
          )}
          className="thread"
        />
      ) : null}
      {away && rows.length ? (
        <Button
          variant="outline"
          size="sm"
          className="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-full shadow-sm"
          onClick={() => list.scrollToBottom({ behavior: reducedMotion ? 'auto' : 'smooth' })}
        >
          <ArrowDown />
          Scroll to bottom
        </Button>
      ) : null}
    </div>
  );
}

// ---------- Header ----------

const STATES: Record<string, string> = {
  connecting: 'Connecting',
  starting: 'Starting',
  idle: 'Ready',
  busy: 'Working',
  awaiting_input: 'Needs you',
  ended: 'Ended',
  exited: 'Exited',
};

const MODEL_PRESETS = [
  { value: 'default', label: 'Default', hint: 'Recommended' },
  { value: 'opus', label: 'Opus', hint: 'Deep reasoning' },
  { value: 'sonnet', label: 'Sonnet', hint: 'Balanced' },
  { value: 'haiku', label: 'Haiku', hint: 'Fast' },
  { value: 'opus[1m]', label: 'Opus 1M', hint: '1M context' },
  { value: 'sonnet[1m]', label: 'Sonnet 1M', hint: '1M context' },
  { value: 'opusplan', label: 'Opus Plan', hint: 'Opus plans, Sonnet builds' },
] as const;

const PERMISSION_MODES: Array<{ value: PermissionMode; label: string }> = [
  { value: 'default', label: 'Ask before edits' },
  { value: 'acceptEdits', label: 'Accept edits' },
  { value: 'plan', label: 'Plan mode' },
  { value: 'auto', label: 'Auto mode' },
  { value: 'bypassPermissions', label: 'Bypass permissions' },
];

function prettyModel(model: string): string {
  const preset = MODEL_PRESETS.find((p) => p.value === model.toLowerCase());
  if (preset) return preset.label;
  return model
    .replace(/^claude-/, '')
    .replace(/-\d{8}$/, '')
    .replace(/-(\d+)-(\d+)$/, ' $1.$2')
    .replace(/^\w/, (c) => c.toUpperCase());
}

function matchesPreset(model: string, preset: string): boolean {
  const m = model.trim().toLowerCase();
  if (!m) return false;
  if (m === preset) return true;
  if (preset === 'opus[1m]') return m.includes('opus') && m.includes('1m');
  if (preset === 'sonnet[1m]') return m.includes('sonnet') && m.includes('1m');
  if (preset === 'opusplan') return m.includes('opusplan');
  if (preset === 'opus') return m.includes('opus') && !m.includes('1m') && !m.includes('plan');
  if (preset === 'sonnet') return m.includes('sonnet') && !m.includes('1m');
  if (preset === 'haiku') return m.includes('haiku');
  return false;
}

function ModelMenu({ value }: { value: SessionView }): ReactNode {
  const [custom, setCustom] = useState('');
  const [error, setError] = useState('');
  const [open, setOpen] = useState(false);
  const model = String(value.meta.model ?? '');
  const pending = String(value.meta.model_pending ?? '');
  const shownError = error || String(value.meta.model_error ?? '');
  const canSwitch = value.state === 'idle';
  const pick = async (next: string) => {
    if (!next.trim()) return;
    setError('');
    try {
      await rpc('model.set', { model: next.trim() });
      setCustom('');
      setOpen(false);
    } catch (err) {
      setError((err as Error).message);
    }
  };
  return (
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="sm" className={cn(shownError && 'text-destructive')} title={shownError || 'Switch model'}>
          {pending ? <span className="spinner" /> : null}
          {pending ? `Switching to ${prettyModel(pending)}…` : model ? prettyModel(model) : 'Model'}
          <ChevronDown className="opacity-50" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-64">
        <DropdownMenuLabel className="text-muted-foreground text-xs font-normal">{canSwitch ? 'Model' : 'Switch models when Claude is idle'}</DropdownMenuLabel>
        {MODEL_PRESETS.map((preset) => (
          <DropdownMenuItem key={preset.value} disabled={!canSwitch} onSelect={(event) => (event.preventDefault(), void pick(preset.value))}>
            <span className="flex-1">{preset.label}</span>
            <span className="text-muted-foreground text-xs">{preset.hint}</span>
            {!pending && matchesPreset(model, preset.value) ? <Check /> : <span className="size-4" />}
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator />
        <form
          className="flex gap-1.5 p-1"
          onSubmit={(event) => {
            event.preventDefault();
            void pick(custom);
          }}
        >
          <Input className="h-8" placeholder="Custom model ID…" value={custom} disabled={!canSwitch} onChange={(event) => setCustom(event.target.value)} onKeyDown={(event) => event.stopPropagation()} />
          <Button type="submit" size="sm" variant="secondary" disabled={!canSwitch || !custom.trim()}>
            Set
          </Button>
        </form>
        {shownError ? <p className="text-destructive px-2 pb-1 text-xs">{shownError}</p> : null}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function ModeSelect({ value }: { value: SessionView }): ReactNode {
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
  const mode = String(value.meta.permission_mode || 'default');
  return (
    <Select
      value={mode}
      disabled={pending || value.state === 'awaiting_input' || value.state === 'exited'}
      onValueChange={(next) => {
        setError('');
        setPending(true);
        rpc('mode.set', { mode: next as PermissionMode })
          .catch((err: Error) => setError(err.message))
          .finally(() => setPending(false));
      }}
    >
      <SelectTrigger size="sm" className={cn('h-8 border-transparent shadow-none', error && 'text-destructive')} title={error || 'Permission mode (Shift+Tab in the terminal)'}>
        {pending ? <span className="spinner" /> : null}
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {PERMISSION_MODES.map((option) => (
          <SelectItem key={option.value} value={option.value}>
            {option.label}
          </SelectItem>
        ))}
        {PERMISSION_MODES.some((option) => option.value === mode) ? null : <SelectItem value={mode}>{mode}</SelectItem>}
      </SelectContent>
    </Select>
  );
}

// What the busy badge says, from zclaude's `activity`.
function activityLabel(activity: SessionView['activity'], now: number): string {
  switch (activity.activity) {
    case 'requesting': return 'Waiting for the model';
    case 'thinking': return 'Thinking';
    case 'responding': return 'Writing';
    case 'calling': return activity.tool ? `Calling ${activity.tool}` : 'Calling a tool';
    case 'tool': return activity.tool ? `Running ${activity.tool}` : 'Running a tool';
    case 'compacting': return 'Compacting';
    case 'retrying': {
      const left = activity.retry_at ? Math.max(0, Math.ceil((activity.retry_at - now) / 1000)) : 0;
      return left ? `Retrying in ${left}s` : 'Retrying';
    }
    default: return '';
  }
}

function StateBadge({ value }: { value: SessionView }): ReactNode {
  const { state, activity, turn } = value;
  const [now, setNow] = useState(Date.now());
  const ticking = state === 'busy' || activity.activity === 'retrying';
  useEffect(() => {
    if (!ticking) return;
    const timer = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(timer);
  }, [ticking]);
  // Timed from the turn's own start, so a reload keeps the count.
  const elapsed = state === 'busy' && turn ? now - turn.started_at : 0;
  const busyFor = elapsed > 1000 ? formatDuration(elapsed).replace(/\.\ds$/, 's') : '';
  const label = (state === 'busy' && activityLabel(activity, now)) || STATES[state] || state;
  const tone = state === 'awaiting_input' ? 'bg-warning' : state === 'busy' ? 'bg-foreground animate-pulse' : state === 'idle' ? 'bg-success' : 'bg-muted-foreground';
  return (
    <Badge variant="outline" role="status" className="gap-1.5">
      <span className={cn('size-1.5 rounded-full', tone)} />
      {label}
      {busyFor ? <span className="text-muted-foreground tabular-nums">{busyFor}</span> : null}
    </Badge>
  );
}

function Header({ value }: { value: SessionView }): ReactNode {
  const session = String(value.meta.session_id ?? '');
  const [copied, setCopied] = useState(false);
  return (
    <header className="flex h-11 flex-none items-center gap-1 border-b px-3">
      <h1 className="mr-1 text-sm font-semibold">zclaude</h1>
      <ModelMenu value={value} />
      <ModeSelect value={value} />
      {value.meta.code_mode ? (
        <Badge variant="secondary" title="Claude Code Mode (JS REPL) is active">
          <Code />
          Code Mode
        </Badge>
      ) : null}
      <span className="flex-1" />
      {session ? (
        <Button
          variant="ghost"
          size="sm"
          className="text-muted-foreground font-mono text-xs"
          title={`Copy session id ${session}`}
          onClick={() => {
            void navigator.clipboard?.writeText(session).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1200);
            });
          }}
        >
          {copied ? <Check /> : <Copy />}
          {session.slice(0, 8)}
        </Button>
      ) : null}
      {value.state === 'exited' ? (
        <Button variant="outline" size="sm" onClick={() => void rpc('playground.restart')}>
          <RotateCcw />
          Restart
        </Button>
      ) : null}
      <StateBadge value={value} />
    </header>
  );
}

// ---------- Composer ----------

function Composer({ state }: { state: string }): ReactNode {
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const [transport, setTransport] = useState(() => stored('zclaude.transport', 'inproc'));
  const send = async () => {
    const value = text.trim();
    if (!value) return;
    setError('');
    try {
      if (value.startsWith('/')) await rpc('command', { text: value });
      else await rpc('prompt.send', { text, transport: transport as 'inproc' | 'hook' });
      setText('');
    } catch (err) {
      setError((err as Error).message);
    }
  };
  const busy = state === 'busy';
  return (
    <form
      className="mx-auto w-full max-w-3xl flex-none px-4 pb-4"
      onSubmit={(event) => {
        event.preventDefault();
        void send();
      }}
    >
      <div className="bg-background focus-within:border-ring focus-within:ring-ring/50 rounded-xl border shadow-xs focus-within:ring-[3px]">
        <Textarea
          id="prompt"
          autoFocus
          rows={1}
          value={text}
          placeholder={busy ? 'Add to this turn…' : 'Write to the session, or /command…'}
          aria-label="Prompt"
          className="max-h-56 min-h-12 resize-none border-0 bg-transparent shadow-none focus-visible:ring-0 dark:bg-transparent"
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              void send();
            }
          }}
        />
        <div className="flex items-center gap-2 px-2 pb-2">
          <ToggleGroup
            type="single"
            value={transport}
            aria-label="Deliver via"
            onValueChange={(next) => {
              if (!next) return;
              setTransport(next);
              remember('zclaude.transport', next);
            }}
          >
            <ToggleGroupItem value="inproc" title="A real user turn, typed from inside the process">
              In-process
            </ToggleGroupItem>
            <ToggleGroupItem value="hook" title="A background notification through an asyncRewake hook">
              Hook
            </ToggleGroupItem>
          </ToggleGroup>
          <span className="flex-1" />
          {busy && !text.trim() ? (
            <Button type="button" size="icon-sm" variant="secondary" aria-label="Interrupt" onClick={() => rpc('interrupt').catch((err: Error) => setError(err.message))}>
              <Square className="fill-current" />
            </Button>
          ) : (
            <Button type="submit" size="icon-sm" aria-label="Send" disabled={!text.trim()}>
              <Send />
            </Button>
          )}
        </div>
      </div>
      {error ? (
        <p role="alert" className="text-destructive mt-2 text-xs">
          {error}
        </p>
      ) : null}
    </form>
  );
}

// ---------- App ----------

const SUGGESTIONS = ['Ask me a question using your question tool', 'Read a file here and explain what it does', 'Make a plan, then run a shell command'];

function Empty(): ReactNode {
  return (
    <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center">
      <h2 className="text-lg font-semibold">One session, two surfaces.</h2>
      <p className="text-muted-foreground max-w-md text-sm">Claude Code is running for real on the right. This side reads its live events and writes into the same session.</p>
      <div className="pointer-events-auto flex flex-wrap justify-center gap-2">
        {SUGGESTIONS.map((text) => (
          <Button key={text} variant="outline" size="sm" onClick={() => void rpc('prompt.send', { text, transport: stored('zclaude.transport', 'inproc') as 'inproc' | 'hook' }).catch(() => {})}>
            {text}
          </Button>
        ))}
      </div>
    </div>
  );
}

function useSplit(): (event: React.PointerEvent<HTMLDivElement>) => void {
  useEffect(() => {
    const saved = stored('zclaude.split', '');
    if (saved) document.body.style.setProperty('--split', saved);
  }, []);
  return useCallback((event) => {
    event.preventDefault();
    const divider = event.currentTarget;
    divider.setPointerCapture(event.pointerId);
    document.body.classList.add('resizing');
    const move = (e: PointerEvent) => {
      const percent = Math.min(70, Math.max(28, (e.clientX / innerWidth) * 100));
      document.body.style.setProperty('--split', `${percent.toFixed(2)}%`);
    };
    const up = () => {
      divider.removeEventListener('pointermove', move);
      divider.removeEventListener('pointerup', up);
      document.body.classList.remove('resizing');
      remember('zclaude.split', document.body.style.getPropertyValue('--split'));
    };
    divider.addEventListener('pointermove', move);
    divider.addEventListener('pointerup', up);
  }, []);
}

declare global {
  interface Window {
    __zclaude?: { text(): string; rows(): Row[]; view(): SessionView };
  }
}

export function App(): ReactNode {
  const value = useView();
  const memo = useRef(newMemo());
  const [tick, setTick] = useState(0);
  const { rows, recheckIn, working } = useMemo(() => buildRows(value, Date.now(), memo.current), [value, tick]);
  useEffect(() => {
    if (recheckIn === null) return;
    const timer = setTimeout(() => setTick((n) => n + 1), recheckIn + 20);
    return () => clearTimeout(timer);
  }, [recheckIn, tick]);
  useEffect(() => {
    window.__zclaude = { text: () => rowsToText(rows), rows: () => rows, view: () => view };
  }, [rows]);
  const startResize = useSplit();
  return (
    <div className="grid h-full grid-cols-[minmax(0,var(--split,50%))_1px_minmax(0,1fr)] max-[800px]:grid-cols-1 max-[800px]:grid-rows-[minmax(0,1.25fr)_minmax(0,1fr)]">
      <section aria-label="Conversation" className="flex min-h-0 min-w-0 flex-col">
        <Header value={value} />
        <div className="relative flex min-h-0 flex-1 flex-col">
          <Thread rows={rows} working={working} />
          {rows.length ? null : <Empty />}
        </div>
        <Dock dialogs={value.dialogs} />
        {value.state === 'exited' ? (
          <p className="text-muted-foreground pb-2 text-center text-xs">{`zclaude exited${value.exitCode !== undefined ? ` with code ${value.exitCode}` : ''}.`}</p>
        ) : null}
        <Composer state={value.state} />
      </section>
      <div role="separator" aria-orientation="vertical" className="bg-border hover:bg-ring cursor-col-resize max-[800px]:hidden" onPointerDown={startResize} />
      <TerminalPane />
    </div>
  );
}
