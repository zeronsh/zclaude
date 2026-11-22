package zclaude

// What the session is doing, put together from all of zclaude's sources at once:
// hooks (exact, ordered, carry Claude's own prompt ids), the API stream inside
// Claude's process (tokens, usage, HTTP errors) and the transcript (the record,
// with Claude Code's own end-of-turn marker).
//
// - Turns: `turn.start` and `turn.end`. A turn ends at Stop (or StopFailure, or an
//   interrupt), but `turn.end` waits for the transcript's `turn_duration` line,
//   which Claude Code writes after everything else in the turn. So every `entry`
//   of a turn comes before its `turn.end`.
// - Activity: idle, requesting, thinking, responding, tool, retrying, compacting,
//   waiting, as it changes.
// - Subagents: `agent.start` and `agent.stop`, linked to the tool call that started
//   them, with their own transcripts forwarded as entries.
// - Background tasks: the list Claude Code reports with every Stop.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Stop has fired but the transcript's end marker hasn't come: end the turn anyway.
TURN_END_GRACE_MS :: 2000
// An interrupted turn writes no end marker, only the interrupt line.
TURN_INTERRUPT_GRACE_MS :: 800

Usage :: struct {
	input, output, cache_read, cache_write: i64,
}

Turn :: struct {
	n:             int,
	claude_prompt: string, // Claude Code's prompt_id, from the hooks
	started_at:    i64,    // wall clock
	started_tick:  i64,
	prompts:       [dynamic]string, // zclaude prompt ids the turn took in
	usage:         Usage,
	messages:      int,
	stop_reason:   string,
	ending:        bool,
	status:        string, // done | interrupted | error | exited (static strings)
	error:         string,
	error_details: string,
	last_message:  string,
	duration_ms:   i64,
	cost_start:    f64, // the session's cost when the turn began, if known
	has_cost:      bool,
	status_seq_at_message: int, // status reports seen when its last message finished
	awaiting_status: bool,
}

// A finished subagent's transcript is still read this long: Claude Code writes its
// last lines after SubagentStop. `agent.stop` follows, after all of them.
AGENT_DRAIN_MS :: 1500

Subagent :: struct {
	n:                int,
	id, type, parent: string,
	stopping:         bool,
	last_message:     string,
	// agent.start waits (AGENT_PARENT_WAIT_MS at most) for Claude Code's metadata
	// file, which names the tool call that started the agent.
	announced:        bool,
	started_tick:     i64,
	// Claude Code's own helpers (prompt suggestions, memory) have no agent type.
	internal:         bool,
	tail:             Tail,
}

// ---------- Turns ----------

turn_begin :: proc(claude_prompt := "") {
	h := hub()
	if t := h.turn; t != nil {
		if !t.ending {
			if claude_prompt != "" && t.claude_prompt == "" do t.claude_prompt = strings.clone(claude_prompt)
			return
		}
		turn_finish()
	}
	h.next_turn += 1
	t := new(Turn)
	t.n = h.next_turn
	t.claude_prompt = strings.clone(claude_prompt)
	t.started_at = wall_ms()
	t.started_tick = now_ms()
	t.cost_start, t.has_cost = h.cost_value, h.cost_seen
	h.turn = t
	ev := event("turn.start")
	jw_int(&ev.w, "turn", i64(t.n))
	if t.claude_prompt != "" do jw_str(&ev.w, "claude_prompt_id", t.claude_prompt)
	jw_int(&ev.w, "started_at", t.started_at)
	event_send(ev)
}

// Whether a transcript line with this prompt id belongs to the turn in progress,
// even one already ending: Claude Code can write a turn's lines after its Stop (a
// failed turn's prompt and error come after StopFailure).
in_current_turn :: proc(claude_prompt: string) -> bool {
	t := hub().turn
	return t != nil && claude_prompt != "" && t.claude_prompt == claude_prompt
}

// A prompt sent through zclaude reached the conversation.
turn_took_prompt :: proc(id: string, claude_prompt := "") {
	h := hub()
	if !in_current_turn(claude_prompt) && (h.turn == nil || h.turn.ending) do turn_begin(claude_prompt)
	append(&h.turn.prompts, strings.clone(id))
}

turn_end_begin :: proc(status: string, error_text := "", details := "", last_message := "") {
	h := hub()
	if h.turn == nil do turn_begin()
	t := h.turn
	if t.ending {
		// A failure reported after the stop is the better account of how it ended.
		if status == "error" && t.status != "error" {
			t.status = status
			replace(&t.error, error_text)
			replace(&t.error_details, details)
		}
		return
	}
	t.ending = true
	t.status = status
	t.error = strings.clone(error_text)
	t.error_details = strings.clone(details)
	t.last_message = strings.clone(last_message)
	timer_add(status == "interrupted" ? TURN_INTERRUPT_GRACE_MS : TURN_END_GRACE_MS, .Turn_End, n = t.n)
}

// The transcript's `turn_duration` line: everything in the turn has been written.
turn_marker :: proc(duration_ms: i64) {
	h := hub()
	t := h.turn
	if t == nil || !t.ending do return
	t.duration_ms = duration_ms
	turn_finish_when_costed()
}

turn_timer :: proc(n: int) {
	h := hub()
	t := h.turn
	if t == nil || t.n != n || !t.ending do return
	// The second expiry: the status line didn't report again; end with what's known.
	if t.awaiting_status {
		turn_finish()
		return
	}
	turn_finish_when_costed()
}

// The status line reports the cost of a message shortly after it lands. A turn
// ends once that report for its last message has come (a second at most), so its
// cost is never a stale sample.
STATUS_WAIT_MS :: 1000

turn_finish_when_costed :: proc() {
	h := hub()
	t := h.turn
	if h.cost_seen && h.status_seq == t.status_seq_at_message && t.messages > 0 && !t.awaiting_status {
		t.awaiting_status = true
		timer_add(STATUS_WAIT_MS, .Turn_End, n = t.n)
		return
	}
	turn_finish()
}

turn_finish :: proc() {
	h := hub()
	t := h.turn
	if t == nil do return
	h.turn = nil
	ev := event("turn.end")
	jw_int(&ev.w, "turn", i64(t.n))
	jw_str(&ev.w, "status", t.status != "" ? t.status : "done")
	if t.stop_reason != "" do jw_str(&ev.w, "stop_reason", t.stop_reason)
	if t.claude_prompt != "" do jw_str(&ev.w, "claude_prompt_id", t.claude_prompt)
	jw_arr_key(&ev.w, "prompt_ids")
	for p in t.prompts do jw_str_item(&ev.w, p)
	jw_end_arr(&ev.w)
	jw_int(&ev.w, "started_at", t.started_at)
	jw_int(&ev.w, "ended_at", wall_ms())
	jw_int(&ev.w, "duration_ms", t.duration_ms > 0 ? t.duration_ms : now_ms() - t.started_tick)
	jw_int(&ev.w, "messages", i64(t.messages))
	write_usage(&ev.w, "usage", t.usage)
	// What the turn cost, by Claude Code's own count (its status line).
	if h.cost_seen {
		start := t.has_cost ? t.cost_start : 0
		jw_raw(&ev.w, "cost_usd", fmt.tprintf("%.6f", max(h.cost_value - start, 0)))
	}
	if t.error != "" do jw_str(&ev.w, "error", t.error)
	if t.error_details != "" do jw_str(&ev.w, "error_details", t.error_details)
	if t.last_message != "" do jw_str(&ev.w, "last_message", t.last_message)
	event_send(ev)
	for p in t.prompts do delete(p)
	delete(t.prompts)
	delete(t.claude_prompt)
	delete(t.stop_reason)
	delete(t.error)
	delete(t.error_details)
	delete(t.last_message)
	free(t)
}

write_usage :: proc(w: ^Jw, key: string, u: Usage) {
	jw_obj_key(w, key)
	jw_int(w, "input_tokens", u.input)
	jw_int(w, "output_tokens", u.output)
	jw_int(w, "cache_read_input_tokens", u.cache_read)
	jw_int(w, "cache_creation_input_tokens", u.cache_write)
	jw_end_obj(w)
}

// A main-conversation message finished: it counts toward the turn and sizes the
// context.
turn_add_message :: proc(s: ^Live_Stream) {
	h := hub()
	if s.counted || !s.main do return
	s.counted = true
	if h.turn == nil || h.turn.ending do turn_begin()
	t := h.turn
	t.messages += 1
	t.status_seq_at_message = h.status_seq
	t.usage.input += s.usage.input
	t.usage.output += s.usage.output
	t.usage.cache_read += s.usage.cache_read
	t.usage.cache_write += s.usage.cache_write
	if s.stop_reason != "" do replace(&t.stop_reason, s.stop_reason)
	size := s.usage.input + s.usage.cache_read + s.usage.cache_write + s.usage.output
	if size > 0 do set_meta_int("context_tokens", &h.context_tokens, size)
}

@(private = "file")
replace :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

// ---------- Activity ----------

set_activity :: proc(kind: string, tool := "", retry_at: i64 = 0) {
	h := hub()
	if h.activity == kind && h.activity_tool == tool && h.retry_at == retry_at do return
	h.activity = kind
	replace(&h.activity_tool, tool)
	h.retry_at = retry_at
	h.activity_since = wall_ms()
	ev := event("activity")
	write_activity_fields(&ev.w)
	event_send(ev)
}

write_activity_fields :: proc(w: ^Jw) {
	h := hub()
	jw_str(w, "activity", h.activity != "" ? h.activity : "starting")
	if h.activity_tool != "" do jw_str(w, "tool", h.activity_tool)
	jw_int(w, "since", h.activity_since)
	if h.retry_at > 0 do jw_int(w, "retry_at", h.retry_at)
}

// The activity a state implies, where the state says enough.
activity_for_state :: proc(state: string) {
	h := hub()
	switch state {
	case "starting": set_activity("starting")
	case "idle": set_activity("idle")
	case "awaiting_input": set_activity("waiting")
	case "ended", "exited": set_activity("exited")
	case "busy":
		switch h.activity {
		case "", "idle", "waiting", "starting": set_activity("requesting")
		}
	}
}

// ---------- Subagents ----------

find_agent :: proc(id: string) -> ^Subagent {
	for a in hub().agents do if a.id == id do return a
	return nil
}

agent_parent :: proc(id: string) -> string {
	if a := find_agent(id); a != nil do return a.parent
	return ""
}

agent_start :: proc(params: Value) {
	h := hub()
	id := jstr(params, "agent_id")
	if id == "" || find_agent(id) != nil do return
	a := new(Subagent)
	h.next_agent += 1
	a.n = h.next_agent
	a.id = strings.clone(id)
	a.type = strings.clone(jstr(params, "agent_type"))
	a.internal = a.type == ""
	// <transcript>.jsonl → <transcript>/subagents/agent-<id>.jsonl, as Claude Code lays it out.
	if h.tail.path != "" {
		a.tail.path = fmt.aprintf("%s/subagents/agent-%s.jsonl", strings.trim_suffix(h.tail.path, ".jsonl"), id)
	}
	a.started_tick = now_ms()
	append(&h.agents, a)
	resolve_agent_parent(a)
	if a.parent != "" || a.internal do announce_agent(a)
}

// Claude Code writes an agent's metadata file just after SubagentStart. An agent
// with none (a plugin's own, say) has no tool call behind it.
AGENT_PARENT_WAIT_MS :: 2000

announce_agent :: proc(a: ^Subagent) {
	if a.announced do return
	a.announced = true
	ev := event("agent.start")
	write_agent(&ev.w, a)
	event_send(ev)
}

agent_stop :: proc(params: Value) {
	id := jstr(params, "agent_id")
	a := find_agent(id)
	if a == nil {
		agent_start(params)
		a = find_agent(id)
		if a == nil do return
	}
	if a.stopping do return
	if path := jstr(params, "agent_transcript_path"); path != "" && path != a.tail.path {
		delete(a.tail.path)
		a.tail.path = strings.clone(path)
	}
	resolve_agent_parent(a)
	announce_agent(a)
	a.stopping = true
	a.last_message = strings.clone(jstr(params, "last_assistant_message"))
	if a.internal do agent_drain(a.n)
	else do timer_add(AGENT_DRAIN_MS, .Agent_Drain, n = a.n)
}

// The last read of a finished subagent's transcript, then `agent.stop`.
agent_drain :: proc(n: int) {
	h := hub()
	for a, i in h.agents {
		if a.n != n do continue
		if !a.internal do poll_tail(&a.tail, a)
		ev := event("agent.stop")
		write_agent(&ev.w, a)
		if a.last_message != "" do jw_str(&ev.w, "last_message", a.last_message)
		event_send(ev)
		ordered_remove(&h.agents, i)
		agent_free(a)
		return
	}
}

// Claude has exited: every subagent is finished.
agents_drain_all :: proc() {
	h := hub()
	for len(h.agents) > 0 do agent_drain(h.agents[0].n)
}

agent_free :: proc(a: ^Subagent) {
	if a.tail.has_fd do c_close(a.tail.fd)
	delete(a.tail.path)
	delete(a.tail.partial)
	delete(a.id)
	delete(a.type)
	delete(a.parent)
	delete(a.last_message)
	free(a)
}

write_agent :: proc(w: ^Jw, a: ^Subagent) {
	jw_str(w, "agent_id", a.id)
	jw_str(w, "agent_type", a.type)
	if a.parent != "" do jw_str(w, "parent_tool_use_id", a.parent)
	jw_bool(w, "internal", a.internal)
}

// The tool call that started a subagent, from Claude Code's metadata file for it.
@(private = "file")
resolve_agent_parent :: proc(a: ^Subagent) {
	if a.parent != "" || a.internal || a.tail.path == "" do return
	meta := strings.concatenate({strings.trim_suffix(a.tail.path, ".jsonl"), ".meta.json"}, context.temp_allocator)
	data, err := os.read_entire_file(meta, context.temp_allocator)
	if err != nil do return
	if v, ok := parse_json(string(data)); ok {
		if id := jstr(v, "toolUseId"); id != "" do a.parent = strings.clone(id)
	}
}

poll_agents :: proc() {
	for a in hub().agents {
		if a.internal do continue
		if !a.announced {
			resolve_agent_parent(a)
			if a.parent == "" && now_ms() - a.started_tick < AGENT_PARENT_WAIT_MS do continue
			announce_agent(a)
		}
		poll_tail(&a.tail, a)
	}
}

// ---------- Background tasks ----------

// Claude Code reports its background work (shells, agents, monitors) with every
// Stop and SubagentStop.
update_tasks :: proc(params: Value) {
	h := hub()
	tasks := jget(params, "background_tasks")
	if tasks == nil do return
	text := to_json(tasks, context.temp_allocator)
	if text == h.tasks do return
	delete(h.tasks)
	h.tasks = strings.clone(text)
	ev := event("tasks")
	jw_raw(&ev.w, "tasks", h.tasks)
	event_send(ev)
}

// ---------- From hooks ----------

// Hooks are the exact, ordered account of a turn, and each carries Claude Code's
// prompt_id. Subagents' own hooks say nothing about the main turn.
track_turn :: proc(name, tool: string, params: Value) {
	h := hub()
	switch name {
	case "SubagentStart":
		agent_start(params)
		return
	case "SubagentStop":
		update_tasks(params)
		agent_stop(params)
		return
	}
	if jhas(params, "agent_id") do return
	switch name {
	case "UserPromptSubmit":
		turn_begin(jstr(params, "prompt_id"))
	case "PreToolUse":
		turn_begin(jstr(params, "prompt_id"))
		set_activity("tool", tool)
	case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
		if h.turn != nil && !h.turn.ending do set_activity("requesting")
	case "PreCompact":
		set_activity("compacting")
	case "PostCompact":
		set_activity(h.turn != nil && !h.turn.ending ? "requesting" : "idle")
	case "Stop":
		update_tasks(params)
		turn_end_begin("done", last_message = jstr(params, "last_assistant_message"))
	case "StopFailure":
		details := jget(params, "error_details")
		detail_text := ""
		if s, is_str := details.(json.String); is_str do detail_text = string(s)
		else if details != nil do detail_text = to_json(details, context.temp_allocator)
		error_text := jstr(params, "error")
		if error_text == "" do error_text = "unknown"
		turn_end_begin("error", error_text, detail_text, jstr(params, "last_assistant_message"))
	}
}

// ---------- API retries ----------

// Claude Code retries failed API calls by itself (429, 529, 5xx, dropped
// connections) and says so only on screen, in place of the spinner text: "529
// Overloaded · retrying in 38s · attempt 3/10". No hook fires and the transcript
// records nothing, so this is read off the screen.
Retry :: struct {
	status:      int,
	error:       string,
	retry_in_s:  int,
	attempt:     int,
	max_attempt: int,
}

retry_on_screen :: proc(s: ^Screen) -> (r: Retry, ok: bool) {
	lines := screen_lines(s)
	for i := len(lines) - 1; i >= max(len(lines) - 16, 0); i -= 1 {
		line := lines[i]
		lower := strings.to_lower(line, context.temp_allocator)
		at := strings.index(lower, "retrying in ")
		// Claude Code's wording; a reply that merely mentions retrying has no attempt count.
		if at < 0 || !strings.contains(lower[at:], "attempt ") do continue
		// What came before: "✻ 529 Overloaded · ", spinner glyph first.
		head := strings.trim_space(strings.trim_right(strings.trim_space(line[:at]), "·"))
		if sp := strings.index_byte(head, ' '); sp >= 0 && sp <= 4 do head = strings.trim_space(head[sp:])
		r.status, r.error = leading_number(head)
		r.error = strings.trim_space(r.error)
		tail := lower[at + len("retrying in "):]
		r.retry_in_s, _ = leading_number(tail)
		if a := strings.index(tail, "attempt "); a >= 0 {
			rest: string
			r.attempt, rest = leading_number(tail[a + len("attempt "):])
			if strings.has_prefix(rest, "/") do r.max_attempt, _ = leading_number(rest[1:])
		}
		return r, true
	}
	return {}, false
}

@(private = "file")
leading_number :: proc(s: string) -> (int, string) {
	n, i := 0, 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		n = n * 10 + int(s[i] - '0')
		i += 1
	}
	return n, s[i:]
}

sync_retry :: proc() {
	h := hub()
	r, up := retry_on_screen(app.screen)
	if !up {
		if h.activity == "retrying" do set_activity(h.turn != nil && !h.turn.ending ? "requesting" : "idle")
		h.last_retry_attempt = 0
		return
	}
	if r.attempt == h.last_retry_attempt && h.activity == "retrying" do return
	h.last_retry_attempt = r.attempt
	ev := event("api.retry")
	if r.status > 0 do jw_int(&ev.w, "status", i64(r.status))
	if r.error != "" do jw_str(&ev.w, "error", r.error)
	if r.attempt > 0 do jw_int(&ev.w, "attempt", i64(r.attempt))
	if r.max_attempt > 0 do jw_int(&ev.w, "max_attempts", i64(r.max_attempt))
	jw_int(&ev.w, "retry_in_ms", i64(r.retry_in_s) * 1000)
	event_send(ev)
	set_activity("retrying", retry_at = wall_ms() + i64(r.retry_in_s) * 1000)
}

// ---------- Stopping a background task ----------

// `task.stop` does what a person does: opens /tasks, moves to the task's row and
// presses x, then closes the view. Each step reads the screen first.
Task_Stop :: struct {
	client_id: int,
	req_id:    string,
	id:        string,
	labels:    [2]string, // the task's command and description, as rows show them
	pressed:   bool,      // x was pressed
	steps:     int,
}

TASK_STEP_MS :: 150
TASK_STOP_STEPS :: 40

hub_stop_task :: proc(cl: ^Client, req_id, id: string) -> string {
	h := hub()
	if h.task_stop != nil do return "a task is already being stopped"
	if !h.session_started do return "the session has not started yet"
	tasks, _ := parse_json(h.tasks != "" ? h.tasks : "[]")
	found: Value
	for t in jarr(tasks) do if jstr(t, "id") == id do found = t
	if found == nil do return fmt.tprintf("no background task %q (see the `tasks` event)", id)
	if !can_type_prompt() && h.state != "busy" do return "the terminal is showing a dialog; answer it first"
	if len(h.dialogs) > 0 || card_on_screen(app.screen) || settling() do return "the terminal is showing a dialog; answer it first"
	if composer_draft(app.screen) do return "the prompt box has a draft in it"
	if !prompt_box_visible() do return "the terminal is showing a view; close it first (Esc)"
	ts := new(Task_Stop)
	ts.client_id = cl.id
	ts.req_id = strings.clone(req_id)
	ts.id = strings.clone(id)
	ts.labels[0] = strings.clone(strings.trim_space(jstr(found, "command")))
	ts.labels[1] = strings.clone(strings.trim_space(jstr(found, "description")))
	h.task_stop = ts
	route := input_route()
	send_input(route, transmute([]u8)string("\x1b[200~/tasks\x1b[201~"))
	timer_add(KEY_DELAY_MS, .Input, "\r", route)
	timer_add(KEY_DELAY_MS + 400, .Task_Step)
	return ""
}

task_stop_step :: proc() {
	h := hub()
	ts := h.task_stop
	if ts == nil do return
	finish :: proc(err: string) {
		h := hub()
		ts := h.task_stop
		if cl := client_by_id(ts.client_id); cl != nil {
			if err != "" do reply_error(cl, ts.req_id, err)
			else do reply_result(cl, ts.req_id, fmt.tprintf(`{{"task_id":"%s","stopped":true}}`, ts.id))
		}
		if err == "" do drop_task(ts.id)
		delete(ts.req_id)
		delete(ts.id)
		delete(ts.labels[0])
		delete(ts.labels[1])
		free(ts)
		h.task_stop = nil
	}
	ts.steps += 1
	view := tasks_view(app.screen, ts.labels[:])
	if ts.pressed {
		// Stopped: its row has gone. Close the view as Esc would.
		if view.open && view.target >= 0 && ts.steps < TASK_STOP_STEPS {
			timer_add(TASK_STEP_MS, .Task_Step)
			return
		}
		if view.open do pty_write(transmute([]u8)string("\x1b"))
		finish("")
		return
	}
	if ts.steps >= TASK_STOP_STEPS {
		if !prompt_box_visible() do pty_write(transmute([]u8)string("\x1b"))
		finish("could not find the task in /tasks")
		return
	}
	defer timer_add(TASK_STEP_MS, .Task_Step)
	if !view.open do return
	switch {
	case view.detail && view.target >= 0:
		pty_write(transmute([]u8)string("x"))
		ts.pressed = true
	case view.detail:
		key, _ := key_bytes("left")
		pty_write(transmute([]u8)key)
	case view.target < 0:
		// Not in the list (yet).
	case view.cursor == view.target:
		pty_write(transmute([]u8)string("x"))
		ts.pressed = true
	case:
		key, _ := key_bytes(view.cursor < view.target ? "down" : "up")
		pty_write(transmute([]u8)key)
	}
}

Tasks_View :: struct {
	open, detail:   bool,
	cursor, target: int, // row indexes in the list; target is the row (or detail) of the task
}

// Reads the /tasks view: a list ("↑/↓ to navigate · x to stop") or one task's
// detail ("← to go back · x to stop").
tasks_view :: proc(s: ^Screen, labels: []string) -> (v: Tasks_View) {
	v.cursor, v.target = -1, -1
	lines := screen_lines(s)
	footer := -1
	seen := 0
	for i := len(lines) - 1; i >= 0 && seen < 6; i -= 1 {
		l := lines[i]
		if strings.trim_space(l) == "" do continue
		seen += 1
		if strings.contains(l, "to navigate") || strings.contains(l, "to go back") || strings.contains(l, "x to stop") {
			footer = i
			v.detail = strings.contains(l, "to go back")
			break
		}
	}
	if footer < 0 do return
	v.open = true
	matches :: proc(text: string, labels: []string) -> bool {
		for label in labels {
			if label == "" do continue
			probe := label[:min(len(label), 40)]
			if strings.contains(text, probe) do return true
		}
		return false
	}
	// The view starts after the rule drawn above it.
	top := 0
	for i := footer - 1; i >= 0; i -= 1 {
		if strings.count(lines[i], "▔") >= 10 || strings.count(lines[i], "─") >= 10 {
			top = i + 1
			break
		}
	}
	if v.detail {
		for l in lines[top:footer] do if matches(l, labels) do v.target = 0
		return
	}
	row := 0
	for l in lines[top:footer] {
		t := strings.trim_space(l)
		marked := strings.has_prefix(t, "❯")
		t = strings.trim_left_space(strings.trim_prefix(t, "❯"))
		// A row starts with its status bullet, which differs by platform (● on Linux,
		// ⏺ on macOS); headings start with a word or a number.
		first, _ := utf8.decode_rune_in_string(t)
		if first < 0x2000 || (first >= 0x2500 && first <= 0x259F) do continue
		if marked do v.cursor = row
		if v.target < 0 && matches(t, labels) do v.target = row
		row += 1
	}
	return
}

// A stopped task leaves the list at once; the next Stop reports the rest.
@(private = "file")
drop_task :: proc(id: string) {
	h := hub()
	tasks, ok := parse_json(h.tasks != "" ? h.tasks : "[]")
	if !ok do return
	kept := make(Array, 0, context.temp_allocator)
	for t in jarr(tasks) do if jstr(t, "id") != id do append(&kept, t)
	text := to_json(kept, context.temp_allocator)
	if text == h.tasks do return
	delete(h.tasks)
	h.tasks = strings.clone(text)
	ev := event("tasks")
	jw_raw(&ev.w, "tasks", h.tasks)
	event_send(ev)
}

// ---------- Claude Code's own records ----------

// The main conversation's queries are repl_main_thread (and its variants, such as
// compaction); subagents' are agent:…; side calls (titles, suggestions) are others.
is_main_query :: proc(source: string) -> bool {
	return source == "repl_main_thread" || strings.has_prefix(source, "repl_main_thread:")
}

MAX_REQUESTS :: 512

note_request :: proc(id, source: string) {
	h := hub()
	if id == "" || source == "" || id in h.requests do return
	key := strings.clone(id)
	h.requests[key] = strings.clone(source)
	append(&h.request_order, key)
	if len(h.request_order) > MAX_REQUESTS {
		old := h.request_order[0]
		ordered_remove(&h.request_order, 0)
		delete(h.requests[old])
		delete_key(&h.requests, old)
		delete(old)
	}
}

// UserPromptSubmit names the prompt Claude Code took and its prompt_id: a prompt
// zclaude typed with that text is that one, and its entries carry the id.
bind_prompt :: proc(text, claude_id: string) {
	h := hub()
	if claude_id == "" do return
	for p in h.in_flight {
		if p.claude_id == "" && prompt_matches(p.text, text) {
			p.claude_id = strings.clone(claude_id)
			return
		}
	}
}

// ---------- The status line ----------

// Claude Code's status line input: its own live account of cost, the context
// window, rate limits, effort and model.
hub_on_status :: proc(v: Value) {
	h := hub()
	h.status_seq += 1
	defer if t := h.turn; t != nil && t.awaiting_status do turn_finish()
	// The fields every hook carries: the session, its transcript, the permission mode.
	hook_common(v)
	#partial switch cost in jget(v, "cost", "total_cost_usd") {
	case json.Float:
		h.cost_value, h.cost_seen = f64(cost), true
	case json.Integer:
		h.cost_value, h.cost_seen = f64(cost), true
	}
	if h.cost_seen do set_meta_raw("cost_usd", &h.cost_usd, fmt.tprintf("%.6f", h.cost_value))
	if cw, ok := jget(v, "context_window").(Object); ok {
		b := strings.builder_make(context.temp_allocator)
		w := jw_make(&b)
		jw_obj(&w)
		number :: proc(w: ^Jw, key: string, value: Value) {
			#partial switch x in value {
			case json.Integer, json.Float: jw_value(w, key, x)
			}
		}
		number(&w, "window_tokens", cw["context_window_size"])
		number(&w, "used_percentage", cw["used_percentage"])
		number(&w, "input_tokens", cw["total_input_tokens"])
		number(&w, "output_tokens", cw["total_output_tokens"])
		jw_end_obj(&w)
		set_meta_raw("context", &h.context_info, strings.to_string(b))
	}
	if limits := jget(v, "rate_limits"); limits != nil do set_meta_raw("rate_limits", &h.rate_limits, to_json(limits, context.temp_allocator))
	if effort := jstr(v, "effort", "level"); effort != "" do set_meta("effort", &h.effort, effort)
	if model := jstr(v, "model", "id"); model != "" && h.model_pending == "" do set_meta("model", &h.model, model)
	if thinking, ok := jget(v, "thinking", "enabled").(json.Boolean); ok do set_meta_bool("thinking", &h.thinking, bool(thinking))
	if fast, ok := jget(v, "fast_mode").(json.Boolean); ok do set_meta_bool("fast_mode", &h.fast_mode, bool(fast))
}

// ---------- Effort for this session ----------

// `/effort LEVEL` also saves the level as the default for new sessions. The /model
// picker can change it for this session alone: ←/→ moves the effort, `s` applies
// it "for this session only" to the model already chosen. zclaude drives the picker
// that way, reading the screen before each key.
Effort_Task :: struct {
	client_id: int,
	req_id:    string,
	target:    string,
	steps:     int,
	pressed:   bool,
}

EFFORT_ORDER :: []string{"low", "medium", "high", "xhigh", "max"}
EFFORT_STEP_MS :: 150
EFFORT_STEPS :: 40

hub_set_effort_session :: proc(cl: ^Client, req_id, level: string) -> string {
	h := hub()
	if !h.session_started do return "the session has not started yet"
	if h.state != "idle" do return "cannot change effort while Claude is busy"
	if h.effort_task != nil || h.task_stop != nil || h.mode_task != nil do return "another change is already running"
	if len(h.dialogs) > 0 || card_on_screen(app.screen) || settling() do return "a dialog is open; answer it first"
	if composer_draft(app.screen) do return "the prompt box has a draft in it"
	if !prompt_box_visible() do return "the terminal is showing a view; close it first (Esc)"
	if h.effort == level {
		reply_result(cl, req_id, fmt.tprintf(`{{"effort":"%s","status":"set"}}`, level))
		return ""
	}
	t := new(Effort_Task)
	t.client_id = cl.id
	t.req_id = strings.clone(req_id)
	t.target = strings.clone(level)
	h.effort_task = t
	route := input_route()
	send_input(route, transmute([]u8)string("\x1b[200~/model\x1b[201~"))
	timer_add(KEY_DELAY_MS, .Input, "\r", route)
	timer_add(KEY_DELAY_MS + 300, .Effort_Step)
	return ""
}

effort_step :: proc() {
	h := hub()
	t := h.effort_task
	if t == nil do return
	finish :: proc(err: string) {
		h := hub()
		t := h.effort_task
		if cl := client_by_id(t.client_id); cl != nil {
			if err != "" do reply_error(cl, t.req_id, err)
			else do reply_result(cl, t.req_id, fmt.tprintf(`{{"effort":"%s","status":"set"}}`, t.target))
		}
		if err == "" do set_meta("effort", &h.effort, t.target)
		delete(t.req_id)
		delete(t.target)
		free(t)
		h.effort_task = nil
	}
	t.steps += 1
	level, open := effort_on_screen(app.screen)
	if t.pressed {
		if !open {
			finish("")
			return
		}
	} else if t.steps >= EFFORT_STEPS {
		if !prompt_box_visible() do pty_write(transmute([]u8)string("\x1b"))
		finish(open ? fmt.tprintf("could not reach %s effort in the model picker", t.target) : "the model picker has no effort setting for this model")
		return
	}
	if t.steps >= EFFORT_STEPS * 2 {
		finish("the model picker did not close")
		return
	}
	defer timer_add(EFFORT_STEP_MS, .Effort_Step)
	if !open || t.pressed do return
	// The choice stays the model in use (marked ✔), so only the effort changes.
	menu := screen_menu(app.screen)
	current := -1
	for label, i in menu.labels do if strings.contains(label, "✔") do current = i
	if current >= 0 && menu.cursor >= 0 && menu.cursor != current {
		key, _ := key_bytes(menu.cursor < current ? "down" : "up")
		pty_write(transmute([]u8)key)
		return
	}
	if level == t.target {
		pty_write(transmute([]u8)string("s"))
		t.pressed = true
		return
	}
	have, want := -1, -1
	for l, i in EFFORT_ORDER {
		if l == level do have = i
		if l == t.target do want = i
	}
	key, _ := key_bytes(have >= 0 && have > want ? "left" : "right")
	pty_write(transmute([]u8)key)
}

// The picker's effort row, as in "◐ Medium effort (default) ←/→ to adjust".
effort_on_screen :: proc(s: ^Screen) -> (level: string, open: bool) {
	for raw in screen_lines(s) {
		line := strings.to_lower(raw, context.temp_allocator)
		if !strings.contains(line, "to adjust") do continue
		at := strings.index(line, " effort")
		if at < 0 do continue
		before := strings.trim_space(line[:at])
		switch {
		case strings.has_suffix(before, "extra high"), strings.has_suffix(before, "xhigh"), strings.has_suffix(before, "x-high"): return "xhigh", true
		case strings.has_suffix(before, "max"): return "max", true
		case strings.has_suffix(before, "high"): return "high", true
		case strings.has_suffix(before, "medium"): return "medium", true
		case strings.has_suffix(before, "low"): return "low", true
		}
		return "", true
	}
	return "", false
}

// ---------- The prompt box ----------

// Whether the prompt box holds a draft: text after its "❯" that isn't the dim
// placeholder Claude Code shows in an empty box. A person may be mid-sentence in an
// interactive session, and anything typed now would join their draft.
composer_draft :: proc(s: ^Screen) -> bool {
	cells := buf(s)
	lines := screen_lines(s)
	// A rule: a line drawn across, possibly with a title in it ("──── name ─").
	is_rule_line :: proc(line: string) -> bool {
		t := strings.trim_space(line)
		if t == "" do return false
		first, _ := utf8.decode_rune_in_string(t)
		if first < 0x2500 || first > 0x259F do return false
		n := 0
		for r in t do if r >= 0x2500 && r <= 0x259F do n += 1
		return n >= 10
	}
	// The box sits between two rules just above the footer: find the lower rule,
	// then read up to the upper one.
	bottom := -1
	for y := len(lines) - 1; y >= max(len(lines) - 8, 0); y -= 1 {
		if is_rule_line(lines[y]) {
			bottom = y
			break
		}
	}
	if bottom < 1 do return false
	top := -1
	for y := bottom - 1; y >= max(bottom - 12, 0); y -= 1 {
		if is_rule_line(lines[y]) {
			top = y
			break
		}
	}
	if top < 0 || !strings.has_prefix(strings.trim_left_space(lines[top + 1]), "❯") do return false
	for row in top + 1 ..< bottom {
		seen_prompt := row != top + 1
		for x in 0 ..< s.cols {
			c := cells[row * s.cols + x]
			// Claude Code draws the empty box as "❯" and a no-break space.
			if c.ch == 0 || unicode.is_space(c.ch) do continue
			if !seen_prompt {
				if c.ch == '❯' do seen_prompt = true
				continue
			}
			// What a person typed; the placeholder in an empty box is dim.
			if c.attr.flags & ATTR_DIM == 0 do return true
		}
	}
	return false
}

// The prompt box is up (its footer, with the mode indicator, shows): no view or card
// covers it, so what is typed goes into it.
prompt_box_visible :: proc() -> bool {
	_, ok := detect_mode(app.screen)
	return ok
}
