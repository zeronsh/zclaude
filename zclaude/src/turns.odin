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
}

// A finished subagent's transcript is still read this long: Claude Code writes its
// last lines after SubagentStop. `agent.stop` follows, after all of them.
AGENT_DRAIN_MS :: 1500

Subagent :: struct {
	n:                int,
	id, type, parent: string,
	stopping:         bool,
	last_message:     string,
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
	h.turn = t
	ev := event("turn.start")
	jw_int(&ev.w, "turn", i64(t.n))
	if t.claude_prompt != "" do jw_str(&ev.w, "claude_prompt_id", t.claude_prompt)
	jw_int(&ev.w, "started_at", t.started_at)
	event_send(ev)
}

// A prompt sent through zclaude reached the conversation.
turn_took_prompt :: proc(id: string) {
	h := hub()
	if h.turn == nil || h.turn.ending do turn_begin()
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
	turn_finish()
}

turn_timer :: proc(n: int) {
	h := hub()
	if h.turn != nil && h.turn.n == n && h.turn.ending do turn_finish()
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
	append(&h.agents, a)
	resolve_agent_parent(a)
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

// The tool call that started a subagent: Claude Code's metadata file names it; until
// that is written, the oldest unclaimed Agent call for the same agent type.
@(private = "file")
resolve_agent_parent :: proc(a: ^Subagent) {
	h := hub()
	if a.parent != "" || a.internal do return
	if a.tail.path != "" {
		meta := strings.concatenate({strings.trim_suffix(a.tail.path, ".jsonl"), ".meta.json"}, context.temp_allocator)
		if data, err := os.read_entire_file(meta, context.temp_allocator); err == nil {
			if v, ok := parse_json(string(data)); ok {
				if id := jstr(v, "toolUseId"); id != "" {
					a.parent = strings.clone(id)
					return
				}
			}
		}
	}
	outer: for t in h.pending_tools {
		if t.name != "Agent" && t.name != "Task" do continue
		input, _ := parse_json(t.input)
		if jstr(input, "subagent_type") != a.type && !(a.type == "general-purpose" && jstr(input, "subagent_type") == "") do continue
		for other in h.agents do if other != a && other.parent == t.id do continue outer
		a.parent = strings.clone(t.id)
		return
	}
}

poll_agents :: proc() {
	for a in hub().agents {
		if a.internal do continue
		if a.parent == "" do resolve_agent_parent(a)
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
		if view.open do pty_write(transmute([]u8)string("\x1b"))
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
		if !strings.has_prefix(t, "●") && !strings.has_prefix(t, "○") && !strings.has_prefix(t, "◯") do continue
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
