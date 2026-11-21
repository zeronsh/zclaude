// Dialogs waiting on a person, docked above the composer so they stay in view
// however far the conversation has scrolled. Each answer goes to zclaude as
// `dialog.respond`; the terminal shows the same dialog, and whoever answers first wins.
import type { DialogView } from '@zclaude/client/store';
import { ShieldAlert, MessageCircleQuestion, ClipboardList, Plug } from 'lucide-react';
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Badge } from './components/ui/badge.tsx';
import { Button } from './components/ui/button.tsx';
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from './components/ui/card.tsx';
import { Checkbox } from './components/ui/checkbox.tsx';
import { Input } from './components/ui/input.tsx';
import { Label } from './components/ui/label.tsx';
import { RadioGroup, RadioGroupItem } from './components/ui/radio-group.tsx';
import { Textarea } from './components/ui/textarea.tsx';
import { OPEN_DIALOG } from './model.ts';
import { rpc } from './net.ts';
import { unwrapShell } from './tools.ts';

interface Question {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: Array<{ label: string; description?: string }> | null;
}

interface Answer {
  selected: string[];
  other: string;
}

interface CardProps {
  dialog: DialogView;
  active: boolean;
}

function useRespond(id: string): { send: (response: Record<string, unknown>) => Promise<void>; error: string; busy: boolean } {
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const send = async (response: Record<string, unknown>) => {
    setError('');
    setBusy(true);
    try {
      await rpc('dialog.respond', { id, ...response } as any);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return { send, error, busy };
}

/** Keyboard shortcuts for the card on screen, unless focus is somewhere typing. */
function useCardKeys(active: boolean, keys: { enter?: () => void; escape?: () => void; digit?: (n: number) => void }): void {
  const latest = useRef(keys);
  latest.current = keys;
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement;
      if (target.closest?.('#terminal') || target.matches?.('input, textarea, [role=radio], [role=checkbox]')) return;
      if (event.key === 'Enter' && latest.current.enter && !target.matches?.('button')) {
        event.preventDefault();
        latest.current.enter();
      } else if (event.key === 'Escape' && latest.current.escape) {
        event.preventDefault();
        latest.current.escape();
      } else if (/^[1-9]$/.test(event.key) && latest.current.digit) {
        latest.current.digit(Number(event.key));
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [active]);
}

function Status({ dialog, error }: { dialog: DialogView; error: string }): ReactNode {
  const text = error || (!dialog.held ? 'Answer this one in the terminal.' : dialog.touched ? 'Someone is typing in the terminal.' : '');
  if (!text) return null;
  return <span className={error ? 'text-destructive text-xs' : 'text-muted-foreground text-xs'}>{text}</span>;
}

function Kbd({ children }: { children: ReactNode }): ReactNode {
  return <kbd className="text-muted-foreground ml-1 font-mono text-[10px]">{children}</kbd>;
}

function QuestionCard({ dialog, active }: CardProps): ReactNode {
  const questions: Question[] = dialog.input?.questions ?? [];
  const [answers, setAnswers] = useState<Answer[]>(() => questions.map(() => ({ selected: [], other: '' })));
  const { send, error, busy } = useRespond(dialog.id);
  const blocked = !active || busy || !dialog.held;
  const instant = questions.length === 1 && !questions[0]?.multiSelect;
  const submit = (value = answers) => send({ answers: value });
  const decline = () => send({ decision: 'cancel' });
  const update = (index: number, next: Answer) => {
    const value = answers.map((answer, i) => (i === index ? next : answer));
    setAnswers(value);
    return value;
  };
  const toggle = (index: number, question: Question, label: string) => {
    const current = answers[index]!;
    if (question.multiSelect) {
      const selected = current.selected.includes(label) ? current.selected.filter((s) => s !== label) : [...current.selected, label];
      update(index, { ...current, selected });
    } else {
      const value = update(index, { selected: [label], other: '' });
      if (instant) void submit(value);
    }
  };
  useCardKeys(active && !blocked, {
    enter: () => void submit(),
    escape: () => void decline(),
    digit: (n) => {
      const question = questions[0];
      const option = question?.options?.[n - 1];
      if (questions.length === 1 && question && option) toggle(0, question, option.label);
    },
  });
  return (
    <form
      hidden={!active}
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <Card className="gap-3">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-sm">
            <MessageCircleQuestion className="size-4" />
            Claude is asking
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-5">
          {questions.map((question, index) => {
            const answer = answers[index]!;
            const options = question.options ?? [];
            return (
              <fieldset key={index} className="flex flex-col gap-2.5" disabled={blocked}>
                <legend className="mb-2 text-sm font-medium">
                  {question.header ? (
                    <Badge variant="secondary" className="mr-2">
                      {question.header}
                    </Badge>
                  ) : null}
                  {question.question}
                </legend>
                {question.multiSelect ? (
                  options.map((option) => (
                    <Label key={option.label} className="items-start font-normal">
                      <Checkbox checked={answer.selected.includes(option.label)} onCheckedChange={() => toggle(index, question, option.label)} />
                      <OptionText option={option} />
                    </Label>
                  ))
                ) : (
                  <RadioGroup value={answer.selected[0] ?? ''} onValueChange={(label) => toggle(index, question, label)}>
                    {options.map((option, i) => (
                      <Label key={option.label} className="items-start font-normal">
                        <RadioGroupItem value={option.label} />
                        <OptionText option={option} />
                        {questions.length === 1 ? <Kbd>{i + 1}</Kbd> : null}
                      </Label>
                    ))}
                  </RadioGroup>
                )}
                <Input
                  placeholder={options.length ? 'Something else…' : 'Your answer'}
                  aria-label={`Your own answer to: ${question.question}`}
                  value={answer.other}
                  onChange={(event) => update(index, { selected: question.multiSelect ? answer.selected : [], other: event.target.value })}
                />
              </fieldset>
            );
          })}
        </CardContent>
        <CardFooter>
          <Button type="submit" size="sm" disabled={blocked}>
            Submit
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={blocked} onClick={() => void decline()}>
            Decline <Kbd>esc</Kbd>
          </Button>
          <Status dialog={dialog} error={error} />
        </CardFooter>
      </Card>
    </form>
  );
}

function OptionText({ option }: { option: { label: string; description?: string } }): ReactNode {
  return (
    <span className="flex flex-col gap-0.5">
      <span>{option.label}</span>
      {option.description && option.description !== option.label ? <span className="text-muted-foreground text-xs">{option.description}</span> : null}
    </span>
  );
}

function preview(input: any): string {
  if (typeof input?.command === 'string') return unwrapShell(input.command);
  if (typeof input?.code === 'string') return input.code;
  if (typeof input?.file_path === 'string') return input.file_path;
  return JSON.stringify(input ?? {}, null, 2);
}

function PermissionCard({ dialog, active }: CardProps): ReactNode {
  const { send, error, busy } = useRespond(dialog.id);
  const [message, setMessage] = useState('');
  const blocked = !active || busy || !dialog.held;
  const canAlways = Array.isArray(dialog.suggestions) && dialog.suggestions.length > 0;
  const deny = () => send(message.trim() ? { decision: 'deny', message: message.trim() } : { decision: 'deny' });
  useCardKeys(active && !blocked, { enter: () => void send({ decision: 'allow' }), escape: () => void deny() });
  const tool = dialog.tool === 'REPL' || dialog.tool === 'Eval' ? 'Code' : dialog.tool;
  return (
    <Card className="gap-3" hidden={!active}>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-sm">
          <ShieldAlert className="size-4" />
          {tool} needs permission
        </CardTitle>
        {dialog.input?.description ? <CardDescription>{String(dialog.input.description)}</CardDescription> : null}
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        <pre className="bg-muted max-h-48 overflow-auto rounded-md p-3 font-mono text-xs whitespace-pre-wrap">{preview(dialog.input)}</pre>
        <Input placeholder="Tell Claude why, if denying (optional)" value={message} disabled={blocked} onChange={(event) => setMessage(event.target.value)} />
      </CardContent>
      <CardFooter className="flex-wrap">
        <Button size="sm" disabled={blocked} onClick={() => void send({ decision: 'allow' })}>
          Allow once <Kbd>⏎</Kbd>
        </Button>
        {canAlways ? (
          <Button size="sm" variant="secondary" disabled={blocked} onClick={() => void send({ decision: 'allow_always' })}>
            Always allow
          </Button>
        ) : null}
        <Button size="sm" variant="outline" disabled={blocked} onClick={() => void deny()}>
          Deny <Kbd>esc</Kbd>
        </Button>
        <Status dialog={dialog} error={error} />
      </CardFooter>
    </Card>
  );
}

const PLAN_MODES = [
  { value: 'default', label: 'Approve' },
  { value: 'acceptEdits', label: 'Approve, accept edits' },
  { value: 'auto', label: 'Approve, auto mode' },
] as const;

function PlanCard({ dialog, active }: CardProps): ReactNode {
  const { send, error, busy } = useRespond(dialog.id);
  const [feedback, setFeedback] = useState('');
  const blocked = !active || busy || !dialog.held;
  const reject = () => send(feedback.trim() ? { decision: 'reject', message: feedback.trim() } : { decision: 'reject' });
  useCardKeys(active && !blocked, { enter: () => void send({ decision: 'approve', mode: 'default' }), escape: () => void reject() });
  return (
    <Card className="gap-3" hidden={!active}>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-sm">
          <ClipboardList className="size-4" />
          Claude has a plan
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        <pre className="bg-muted max-h-64 overflow-auto rounded-md p-3 font-sans text-sm whitespace-pre-wrap">{String(dialog.input?.plan ?? '')}</pre>
        <Textarea placeholder="Feedback, if rejecting (optional)" className="min-h-10" value={feedback} disabled={blocked} onChange={(event) => setFeedback(event.target.value)} />
      </CardContent>
      <CardFooter className="flex-wrap">
        {PLAN_MODES.map((mode, i) => (
          <Button key={mode.value} size="sm" variant={i === 0 ? 'default' : 'secondary'} disabled={blocked} onClick={() => void send({ decision: 'approve', mode: mode.value })}>
            {mode.label}
            {i === 0 ? <Kbd>⏎</Kbd> : null}
          </Button>
        ))}
        <Button size="sm" variant="outline" disabled={blocked} onClick={() => void reject()}>
          Keep planning <Kbd>esc</Kbd>
        </Button>
        <Status dialog={dialog} error={error} />
      </CardFooter>
    </Card>
  );
}

function ElicitationCard({ dialog, active }: CardProps): ReactNode {
  const { send, error, busy } = useRespond(dialog.id);
  const properties: Record<string, any> = dialog.input?.requested_schema?.properties ?? {};
  const [values, setValues] = useState<Record<string, string>>({});
  const blocked = !active || busy || !dialog.held;
  const content = () => {
    const out: Record<string, unknown> = {};
    for (const [key, schema] of Object.entries(properties)) {
      const raw = values[key] ?? '';
      if (raw === '') continue;
      out[key] = schema?.type === 'number' || schema?.type === 'integer' ? Number(raw) : schema?.type === 'boolean' ? raw === 'true' : raw;
    }
    return out;
  };
  useCardKeys(active && !blocked, { escape: () => void send({ action: 'cancel' }) });
  return (
    <Card className="gap-3" hidden={!active}>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-sm">
          <Plug className="size-4" />
          {dialog.input?.server || 'An MCP server'} is asking
        </CardTitle>
        <CardDescription>{String(dialog.input?.message ?? '')}</CardDescription>
      </CardHeader>
      {Object.keys(properties).length || dialog.input?.url ? (
        <CardContent className="flex flex-col gap-3">
          {dialog.input?.url ? (
            <a className="text-sm underline" href={dialog.input.url} target="_blank" rel="noreferrer">
              {dialog.input.url}
            </a>
          ) : null}
          {Object.entries(properties).map(([key, schema]) => (
            <div key={key} className="flex flex-col gap-1.5">
              <Label htmlFor={`elicit-${key}`}>{schema?.title ?? key}</Label>
              <Input id={`elicit-${key}`} placeholder={schema?.description ?? ''} value={values[key] ?? ''} disabled={blocked} onChange={(event) => setValues({ ...values, [key]: event.target.value })} />
            </div>
          ))}
        </CardContent>
      ) : null}
      <CardFooter className="flex-wrap">
        <Button size="sm" disabled={blocked} onClick={() => void send({ action: 'accept', content: content() })}>
          Accept
        </Button>
        <Button size="sm" variant="secondary" disabled={blocked} onClick={() => void send({ action: 'decline' })}>
          Decline
        </Button>
        <Button size="sm" variant="outline" disabled={blocked} onClick={() => void send({ action: 'cancel' })}>
          Cancel <Kbd>esc</Kbd>
        </Button>
        <Status dialog={dialog} error={error} />
      </CardFooter>
    </Card>
  );
}

export function Dock({ dialogs }: { dialogs: Record<string, DialogView> }): ReactNode {
  const open = Object.values(dialogs)
    .filter((dialog) => OPEN_DIALOG.has(dialog.status))
    .sort((a, b) => a.created_at - b.created_at);
  const count = open.length;

  // Free the keyboard for shortcuts, unless someone is mid-sentence.
  useEffect(() => {
    if (!count) return;
    const input = document.getElementById('prompt') as HTMLTextAreaElement | null;
    if (document.activeElement === input && input && !input.value) input.blur();
  }, [count]);

  if (!count) return null;
  return (
    <div className="mx-auto flex max-h-[62vh] w-full max-w-3xl flex-none flex-col gap-2 overflow-y-auto px-4 pb-2">
      {open.map((dialog, position) => {
        const props = { dialog, active: position === 0 };
        switch (dialog.kind) {
          case 'question':
            return <QuestionCard key={dialog.id} {...props} />;
          case 'plan':
            return <PlanCard key={dialog.id} {...props} />;
          case 'elicitation':
            return <ElicitationCard key={dialog.id} {...props} />;
          default:
            return <PermissionCard key={dialog.id} {...props} />;
        }
      })}
      {count > 1 ? <span className="text-muted-foreground text-center text-xs">{count - 1} more waiting</span> : null}
    </div>
  );
}
