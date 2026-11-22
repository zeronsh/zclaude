package zclaude

// Session state and the events it produces. Nothing here is stored for later: the
// hub keeps only what it needs to act correctly (open dialogs, prompts in flight,
// streams still receiving tokens), and forwards everything else as it happens.

import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

KEY_DELAY_MS :: 120
// The screen is read for the permission mode and plan choices at most this often.
SCREEN_CHECK_MS :: 250
ENTER_RETRY_MS :: 1000
ENTER_RETRIES :: 3

Prompt :: struct {
	id:        string,
	text:      string,
	transport: string, // inproc | hook
	status:    string, // queued | delivered | received | failed
	command:   bool,   // sent by zclaude itself (model switch), not shown as a prompt
	claude_id: string, // Claude Code's prompt_id, once UserPromptSubmit has shown it
	images:    [dynamic]string, // image files attached, pasted as paths ahead of the text
}

Dialog :: struct {
	id:          string,
	kind:        string, // question | permission | plan | elicitation
	tool:        string,
	input:       string, // canonical JSON
	suggestions: string, // JSON array or ""
	created_at:  i64,
	hook_client: int,    // the held hook connection; 0 once it has gone
	hook_req:    string,
	touched:     bool,
	// Plan dialogs: the approve modes the terminal offers, in its order, read from
	// the screen once the card is drawn. Empty until then.
	modes:       [dynamic]string,
	// Answered over RPC by keys on its card: Claude Code then reports it as the
	// terminal's answer, and zclaude knows better.
	rpc_keys:    bool,
}

// After a consumer answers a dialog, Claude Code still has to take the card off the
// screen. Keys typed before that would land in the card, so typing waits until the
// tool reports back, the turn ends, or SETTLE_MS passes.
SETTLE_MS :: 3000

Settle :: struct {
	id:    string, // tool_use_id, perm-N or elicitation id
	tool:  string,
	kind:  string,
	until: i64,
}

Pending_Tool :: struct {
	id, name, input: string,
}

// One-way fingerprints of a request's tool names and system prompt. They tell which
// agent opened a thread. Compaction can change the system prompt and an MCP server
// can change the tools, so sharing either one is enough to match.
Shape :: struct {
	tools, system: string,
}

Live_Block :: struct {
	index:      int,
	type, name: string,
	text:       strings.Builder,
	started_at: i64,
	ended_at:   i64,
}

Live_Stream :: struct {
	n:          int,
	message_id: string,
	model:      string,
	main:       bool,
	status:     string,
	started_at: i64,
	blocks:     [dynamic]^Live_Block,
	usage:      Usage,
	stop_reason: string,
	counted:    bool, // added to its turn
}

Tail :: struct {
	path:        string,
	// Kept open between polls, so a poll with nothing new is one fstat.
	fd:          c.int,
	has_fd:      bool,
	offset:      i64,
	partial:     [dynamic]u8,
	// Lines before this offset predate this process (a resume): forwarded, but
	// they say nothing about the current state.
	catchup_end: i64,
}

Mode_Task :: struct {
	client_id: int,
	req_id:    string,
	target:    string,
	attempts:  int,
	waits:     int, // steps spent waiting for a card to go
	seen:      [dynamic]string,
}

Memory_Request :: struct {
	client_id: int,
	req_id:    string,
}

Hub :: struct {
	state:              string,
	session_started:    bool,
	session_id:         string,
	transcript_path:    string,
	cwd:                string,
	model:              string,
	model_pending:      string,
	model_error:        string,
	code_mode:          bool,
	permission_mode:    string,
	agent_client:       int,
	next_prompt:        int,
	in_flight:          [dynamic]^Prompt,
	inproc_queue:       [dynamic]^Prompt,
	hook_queue:         [dynamic]^Prompt,
	waiter_client:      int,
	tail:               Tail,
	seen:               map[string]bool,
	streams:            map[int]^Live_Stream,
	stream_by_message:  map[string]int,
	in_transcript:      map[string]bool,
	dialogs:            [dynamic]^Dialog,
	pending_tools:      [dynamic]Pending_Tool,
	prompt_submitted:   bool,
	feed_gen:           int,
	main_chain:         map[string]bool,
	main_shape:         Maybe(Shape),
	shape_by_message:   map[string]Shape,
	uses_threads:       bool,
	threadless_main:    bool,
	in_thread_by_msg:   map[string]bool,
	next_dialog:        int,
	next_request:       int,
	memory_requests:    map[int]Memory_Request,
	mode_task:          ^Mode_Task,
	screen_dirty:       bool,
	screen_checked_at:  i64,
	exited_code:        int,
	state_before_dialog: string,
	settle:             Maybe(Settle),
	// When a card with no dialog behind it was first seen, 0 if none is up.
	card_since:         i64,
	turn:               ^Turn,
	next_turn:          int,
	activity:           string, // static strings
	activity_tool:      string,
	activity_since:     i64,
	retry_at:           i64,
	effort:             string,
	context_tokens:     i64,
	cost_usd:           string, // a JSON number, from the transcript's cost-state
	tasks:              string, // JSON array of background tasks
	agents:             [dynamic]^Subagent,
	next_agent:         int,
	last_retry_attempt: int,
	task_stop:          ^Task_Stop,
	effort_task:        ^Effort_Task,
	// From Claude Code's status line.
	cost_value:         f64,
	cost_seen:          bool,
	status_seq:         int, // status line reports so far
	sources:            string, // JSON object: which of zclaude's sources are live
	context_info:       string, // JSON object
	rate_limits:        string, // JSON object
	thinking:           bool,
	fast_mode:          bool,
	// api-request records: request id to the query that made it (repl_main_thread,
	// agent:…), newest last, bounded.
	requests:           map[string]string,
	request_order:      [dynamic]string,
}

hub :: proc() -> ^Hub {
	return &app.hub
}

hub_init :: proc() {
	h := hub()
	h.state = "starting"
	h.permission_mode = ""
}

// ---------- State and meta ----------

set_state :: proc(state: string) {
	h := hub()
	if h.state == state do return
	previous := h.state
	// Where to return once the dialogs are answered: a card can come up while idle.
	if state == "awaiting_input" do h.state_before_dialog = previous
	h.state = state
	ev := event("state")
	jw_str(&ev.w, "state", state)
	jw_str(&ev.w, "previous", previous)
	event_send(ev)
	activity_for_state(state)
}

@(private = "file")
replace_string :: proc(field: ^string, value: string) -> bool {
	if field^ == value do return false
	delete(field^)
	field^ = strings.clone(value)
	return true
}

set_meta :: proc(key: string, field: ^string, value: string) {
	if !replace_string(field, value) do return
	ev := event("meta")
	jw_str(&ev.w, key, value)
	event_send(ev)
}

set_meta_int :: proc(key: string, field: ^i64, value: i64) {
	if field^ == value do return
	field^ = value
	ev := event("meta")
	jw_int(&ev.w, key, value)
	event_send(ev)
}

// `value` is encoded JSON.
set_meta_raw :: proc(key: string, field: ^string, value: string) {
	if !replace_string(field, value) do return
	ev := event("meta")
	jw_raw(&ev.w, key, value)
	event_send(ev)
}

set_meta_bool :: proc(key: string, field: ^bool, value: bool) {
	if field^ == value do return
	field^ = value
	ev := event("meta")
	jw_bool(&ev.w, key, value)
	event_send(ev)
}

agent :: proc() -> ^Client {
	h := hub()
	if h.agent_client == 0 do return nil
	return client_by_id(h.agent_client)
}

// ---------- Snapshot ----------

write_meta :: proc(w: ^Jw) {
	h := hub()
	jw_obj_key(w, "meta")
	jw_str(w, "session_id", h.session_id)
	jw_str(w, "transcript_path", h.transcript_path)
	jw_str(w, "cwd", h.cwd)
	jw_str(w, "model", h.model)
	jw_str(w, "model_pending", h.model_pending)
	jw_str(w, "model_error", h.model_error)
	jw_bool(w, "code_mode", h.code_mode)
	jw_str(w, "permission_mode", h.permission_mode)
	jw_bool(w, "agent_connected", agent() != nil)
	jw_bool(w, "hook_waiter_armed", h.waiter_client != 0 && client_by_id(h.waiter_client) != nil)
	jw_str(w, "effort", h.effort)
	jw_int(w, "context_tokens", h.context_tokens)
	jw_raw(w, "cost_usd", h.cost_usd)
	jw_raw(w, "context", h.context_info != "" ? h.context_info : "null")
	jw_raw(w, "rate_limits", h.rate_limits != "" ? h.rate_limits : "null")
	jw_raw(w, "sources", h.sources != "" ? h.sources : "{}")
	jw_bool(w, "thinking", h.thinking)
	jw_bool(w, "fast_mode", h.fast_mode)
	jw_end_obj(w)
}

write_dialog :: proc(w: ^Jw, d: ^Dialog) {
	jw_str(w, "id", d.id)
	jw_str(w, "kind", d.kind)
	jw_str(w, "tool", d.tool)
	jw_raw(w, "input", d.input)
	jw_raw(w, "suggestions", len(d.suggestions) > 0 ? d.suggestions : "[]")
	jw_str(w, "status", "open")
	jw_int(w, "created_at", d.created_at)
	jw_bool(w, "held", d.hook_client != 0)
	jw_bool(w, "touched", d.touched)
	if d.kind == "plan" do write_modes(w, d)
}

@(private = "file")
write_modes :: proc(w: ^Jw, d: ^Dialog) {
	jw_arr_key(w, "modes")
	for m in d.modes do jw_str_item(w, m)
	jw_end_arr(w)
}

write_prompt :: proc(w: ^Jw, p: ^Prompt) {
	jw_str(w, "id", p.id)
	jw_str(w, "text", p.text)
	jw_str(w, "transport", p.transport)
	jw_str(w, "status", p.status)
}

// Everything a consumer needs to pick up a session in progress.
write_snapshot :: proc(w: ^Jw) {
	h := hub()
	jw_obj(w)
	jw_int(w, "protocol", PROTOCOL_VERSION)
	jw_int(w, "seq", app.seq)
	jw_int(w, "pid", i64(c_getpid()))
	jw_str(w, "mode", app.mode == .Stdio ? "stdio" : "interactive")
	jw_str(w, "socket", app.socket_path)
	jw_str(w, "state", h.state)
	write_meta(w)
	jw_arr_key(w, "dialogs")
	for d in h.dialogs {
		jw_obj_item(w)
		write_dialog(w, d)
		jw_end_obj(w)
	}
	jw_end_arr(w)
	jw_arr_key(w, "prompts")
	for list in ([][dynamic]^Prompt{h.inproc_queue, h.hook_queue, h.in_flight}) {
		for p in list {
			if p.command do continue
			jw_obj_item(w)
			write_prompt(w, p)
			jw_end_obj(w)
		}
	}
	jw_end_arr(w)
	jw_arr_key(w, "streams")
	for _, s in h.streams {
		jw_obj_item(w)
		jw_int(w, "stream", i64(s.n))
		jw_str(w, "message_id", s.message_id)
		jw_str(w, "model", s.model)
		jw_bool(w, "main", s.main)
		jw_str(w, "status", s.status)
		jw_int(w, "started_at", s.started_at)
		write_usage(w, "usage", s.usage)
		jw_arr_key(w, "blocks")
		for b in s.blocks {
			jw_obj_item(w)
			jw_int(w, "index", i64(b.index))
			jw_str(w, "type", b.type)
			jw_str(w, "name", b.name)
			jw_str(w, "text", strings.to_string(b.text))
			jw_int(w, "started_at", b.started_at)
			if b.ended_at > 0 do jw_int(w, "ended_at", b.ended_at)
			jw_end_obj(w)
		}
		jw_end_arr(w)
		jw_end_obj(w)
	}
	jw_end_arr(w)
	jw_obj_key(w, "term")
	jw_int(w, "cols", i64(app.screen.cols))
	jw_int(w, "rows", i64(app.screen.rows))
	jw_end_obj(w)
	jw_obj_key(w, "activity")
	write_activity_fields(w)
	jw_end_obj(w)
	if t := h.turn; t != nil {
		jw_obj_key(w, "turn")
		jw_int(w, "turn", i64(t.n))
		if t.claude_prompt != "" do jw_str(w, "claude_prompt_id", t.claude_prompt)
		jw_int(w, "started_at", t.started_at)
		jw_end_obj(w)
	} else {
		jw_null(w, "turn")
	}
	jw_raw(w, "tasks", h.tasks != "" ? h.tasks : "[]")
	jw_arr_key(w, "agents")
	for a in h.agents {
		jw_obj_item(w)
		write_agent(w, a)
		jw_end_obj(w)
	}
	jw_end_arr(w)
	jw_end_obj(w)
}

snapshot_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	w := jw_make(&b)
	write_snapshot(&w)
	return strings.to_string(b)
}

// ---------- Hooks ----------

// Fields every hook carries. Subagent hooks describe the subagent, not the session.
hook_common :: proc(params: Value) {
	h := hub()
	if jhas(params, "agent_id") do return
	if path := jstr(params, "transcript_path"); path != "" && path != h.tail.path {
		if h.tail.has_fd do c_close(h.tail.fd)
		h.tail.has_fd = false
		delete(h.tail.path)
		clear(&h.tail.partial)
		h.tail.path = strings.clone(path)
		h.tail.offset = 0
		h.tail.catchup_end = 0
		if info, err := os.stat(path, context.temp_allocator); err == nil {
			h.tail.catchup_end = info.size
		}
		set_meta("transcript_path", &h.transcript_path, path)
	}
	if id := jstr(params, "session_id"); id != "" do set_meta("session_id", &h.session_id, id)
	if mode := jstr(params, "permission_mode"); mode != "" do set_meta("permission_mode", &h.permission_mode, mode)
	if effort := jstr(params, "effort", "level"); effort != "" do set_meta("effort", &h.effort, effort)
}

hub_on_hook_event :: proc(params: Value) {
	h := hub()
	name := jstr(params, "hook_event_name")
	tool := jstr(params, "tool_name")
	hook_common(params)

	ev := event("hook")
	jw_str(&ev.w, "name", name)
	if tool != "" do jw_str(&ev.w, "tool", tool)
	if id := jstr(params, "tool_use_id"); id != "" do jw_str(&ev.w, "tool_use_id", id)
	if id := jstr(params, "agent_id"); id != "" {
		jw_str(&ev.w, "agent_id", id)
		if parent := agent_parent(id); parent != "" do jw_str(&ev.w, "parent_tool_use_id", parent)
	}
	if t := jstr(params, "agent_type"); t != "" do jw_str(&ev.w, "agent_type", t)
	if s := jstr(params, "source"); s != "" do jw_str(&ev.w, "source", s)
	if n := jstr(params, "notification_type"); n != "" do jw_str(&ev.w, "notification_type", n)
	if m := jstr(params, "message"); m != "" && name == "Notification" do jw_str(&ev.w, "message", m)
	event_send(ev)

	update_dialogs(name, tool, params)
	if name == "UserPromptSubmit" && !jhas(params, "agent_id") do bind_prompt(jstr(params, "prompt"), jstr(params, "prompt_id"))
	track_turn(name, tool, params)
	if name == "UserPromptSubmit" do h.prompt_submitted = true
	if name == "PostModelSwitch" {
		if model := jstr(params, "to_model"); model != "" {
			set_meta("model", &h.model, model)
			set_meta("model_pending", &h.model_pending, "")
			set_meta("model_error", &h.model_error, "")
		}
	}
	// A new conversation starts a new chain. Compaction fires this too, but continues
	// the same conversation, and a subagent can still be running.
	if name == "SessionStart" && jstr(params, "source") != "compact" {
		clear_string_set(&h.main_chain)
		h.main_shape = nil
		h.threadless_main = false
		// `/clear` starts a fresh session without a user line in the new transcript.
		i := 0
		for i < len(h.in_flight) {
			p := h.in_flight[i]
			if strings.has_prefix(strings.trim_left_space(p.text), "/") {
				prompt_status(p, "received")
				ordered_remove(&h.in_flight, i)
				prompt_free(p)
			} else {
				i += 1
			}
		}
	}

	switch name {
	case "SessionStart":
		h.session_started = true
		if cwd := jstr(params, "cwd"); cwd != "" do set_meta("cwd", &h.cwd, cwd)
		if model := jstr(params, "model"); model != "" && h.model == "" do set_meta("model", &h.model, model)
		set_state("idle")
	case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied":
		set_state("busy")
	case "Stop", "StopFailure":
		set_state("idle")
	case "Notification":
		switch jstr(params, "notification_type") {
		case "permission_prompt", "elicitation_dialog":
			set_state("awaiting_input")
		case "idle_prompt":
			set_state("idle")
		}
	case "SessionEnd":
		set_state("ended")
	}
	if len(h.dialogs) > 0 do set_state("awaiting_input")
	hub_poll_transcript()
}

@(private = "file")
clear_string_set :: proc(m: ^map[string]bool) {
	for k in m do delete(k)
	clear(m)
}

@(private = "file")
set_insert :: proc(m: ^map[string]bool, key: string) {
	if key in m do return
	m[strings.clone(key)] = true
}

@(private = "file")
update_dialogs :: proc(name, tool: string, params: Value) {
	h := hub()
	id := jstr(params, "tool_use_id")
	switch name {
	case "PreToolUse":
		if tool == "REPL" || tool == "Eval" do set_meta_bool("code_mode", &h.code_mode, true)
		append(&h.pending_tools, Pending_Tool{id = strings.clone(id), name = strings.clone(tool), input = to_json(jget(params, "tool_input"))})
	case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
		for i := 0; i < len(h.pending_tools); i += 1 {
			if h.pending_tools[i].id == id {
				pending_tool_free(h.pending_tools[i])
				ordered_remove(&h.pending_tools, i)
				break
			}
		}
		if st, ok := h.settle.?; ok && (st.id == id || (strings.has_prefix(st.id, "perm-") && st.tool == tool)) do settle_end()
		denied := name == "PermissionDenied"
		status := denied ? "denied" : tool == "AskUserQuestion" ? "answered" : tool == "ExitPlanMode" ? "approved" : "allowed"
		if denied && tool == "ExitPlanMode" do status = "rejected"
		answers := ""
		if name == "PostToolUse" && tool == "AskUserQuestion" {
			if a := jget(params, "tool_input", "answers"); a != nil do answers = to_json(a, context.temp_allocator)
		}
		if d := find_dialog(id); d != nil {
			close_dialog(d, status, "terminal", answers)
		} else if tool != "" {
			for synthetic in h.dialogs {
				if strings.has_prefix(synthetic.id, "perm-") && synthetic.tool == tool {
					close_dialog(synthetic, status, "terminal", "")
					break
				}
			}
		}
	case "ElicitationResult":
		if st, ok := h.settle.?; ok && st.kind == "elicitation" do settle_end()
		elicitation := jstr(params, "elicitation_id")
		for d in h.dialogs {
			if d.kind == "elicitation" && (elicitation == "" || d.id == elicitation) {
				action := jstr(params, "action")
				close_dialog(d, action == "" ? "answered" : action, "terminal", "")
				break
			}
		}
	// A turn or session that has ended can't still be showing a dialog.
	case "Stop", "StopFailure", "SessionStart", "SessionEnd":
		cancel_open_dialogs()
		settle_end()
		for t in h.pending_tools do pending_tool_free(t)
		clear(&h.pending_tools)
	}
}

// Holds typing until Claude Code has taken an answered card off the screen.
settle_begin :: proc(d: ^Dialog) {
	h := hub()
	settle_end()
	h.settle = Settle {
		id    = strings.clone(d.id),
		tool  = strings.clone(d.tool),
		kind  = strings.clone(d.kind),
		until = now_ms() + SETTLE_MS,
	}
	// Wakes the loop when the wait runs out, even if nothing else happens.
	timer_add(SETTLE_MS, .Settle)
}

settle_end :: proc() {
	h := hub()
	st, ok := h.settle.?
	if !ok do return
	delete(st.id)
	delete(st.tool)
	delete(st.kind)
	h.settle = nil
}

settling :: proc() -> bool {
	h := hub()
	st, ok := h.settle.?
	if !ok do return false
	if now_ms() >= st.until {
		settle_end()
		return false
	}
	return true
}

pending_tool_free :: proc(t: Pending_Tool) {
	delete(t.id)
	delete(t.name)
	delete(t.input)
}

find_dialog :: proc(id: string) -> ^Dialog {
	if id == "" do return nil
	for d in hub().dialogs {
		if d.id == id do return d
	}
	return nil
}

// A held hook asks for a decision. The TUI shows the same dialog meanwhile, so a
// person at the terminal and a consumer race to answer, and the first one wins.
hub_on_permission_request :: proc(cl: ^Client, req_id: string, params: Value) {
	h := hub()
	hook_common(params)
	tool := jstr(params, "tool_name")
	input := jget(params, "tool_input")
	canonical := to_json(input, context.temp_allocator)

	ev := event("hook")
	jw_str(&ev.w, "name", "PermissionRequest")
	jw_str(&ev.w, "tool", tool)
	event_send(ev)

	dialog_id := ""
	for t in h.pending_tools {
		if t.name == tool && t.input == canonical && find_dialog(t.id) == nil {
			dialog_id = t.id
			break
		}
	}
	if dialog_id == "" {
		// Code Mode's inner tool calls can ask without a top-level PreToolUse.
		h.next_dialog += 1
		dialog_id = fmt.tprintf("perm-%d", h.next_dialog)
	}
	kind := "permission"
	if tool == "AskUserQuestion" do kind = "question"
	else if tool == "ExitPlanMode" do kind = "plan"
	suggestions := ""
	if s := jget(params, "permission_suggestions"); s != nil do suggestions = to_json(s, context.temp_allocator)
	open_dialog(cl, req_id, dialog_id, kind, tool, canonical, suggestions)
}

hub_on_elicitation :: proc(cl: ^Client, req_id: string, params: Value) {
	h := hub()
	hook_common(params)
	id := jstr(params, "elicitation_id")
	if id == "" || find_dialog(id) != nil {
		h.next_dialog += 1
		id = fmt.tprintf("elicit-%d", h.next_dialog)
	}
	b := strings.builder_make(context.temp_allocator)
	w := jw_make(&b)
	jw_obj(&w)
	jw_str(&w, "server", jstr(params, "mcp_server_name"))
	jw_str(&w, "message", jstr(params, "message"))
	if m := jstr(params, "mode"); m != "" do jw_str(&w, "mode", m)
	if u := jstr(params, "url"); u != "" do jw_str(&w, "url", u)
	if s := jget(params, "requested_schema"); s != nil do jw_value(&w, "requested_schema", s)
	jw_end_obj(&w)
	open_dialog(cl, req_id, id, "elicitation", "", strings.to_string(b), "")
}

open_dialog :: proc(cl: ^Client, req_id, id, kind, tool, input, suggestions: string) {
	h := hub()
	d := new(Dialog)
	d.id = strings.clone(id)
	d.kind = strings.clone(kind)
	d.tool = strings.clone(tool)
	d.input = strings.clone(input)
	d.suggestions = strings.clone(suggestions)
	d.created_at = wall_ms()
	d.hook_client = cl != nil ? cl.id : 0
	d.hook_req = strings.clone(req_id)
	append(&h.dialogs, d)
	ev := event("dialog.open")
	write_dialog(&ev.w, d)
	event_send(ev)
	set_state("awaiting_input")
	// The card may be fully drawn before its hook arrives, with no output after.
	h.screen_dirty = true
}

// Releases the held hook. An empty output leaves the decision to the terminal.
@(private = "file")
release_hook :: proc(d: ^Dialog, output: string) {
	if d.hook_client == 0 do return
	if cl := client_by_id(d.hook_client); cl != nil {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "{\"output\":")
		write_quoted(&b, output)
		strings.write_string(&b, "}")
		reply_result(cl, d.hook_req, strings.to_string(b))
	}
	d.hook_client = 0
}

close_dialog :: proc(d: ^Dialog, status, resolved_by: string, answers: string, output := "") {
	h := hub()
	resolved_by := resolved_by
	if d.rpc_keys && resolved_by == "terminal" do resolved_by = "rpc"
	// Only a released hook leaves a card that Claude Code still has to take down.
	if resolved_by == "rpc" && d.hook_client != 0 && output != "" do settle_begin(d)
	release_hook(d, output)
	ev := event("dialog.update")
	jw_str(&ev.w, "id", d.id)
	jw_str(&ev.w, "status", status)
	if resolved_by != "" do jw_str(&ev.w, "resolved_by", resolved_by)
	if answers != "" do jw_raw(&ev.w, "answers", answers)
	event_send(ev)
	for x, i in h.dialogs {
		if x == d {
			ordered_remove(&h.dialogs, i)
			break
		}
	}
	delete(d.id)
	delete(d.kind)
	delete(d.tool)
	delete(d.input)
	delete(d.suggestions)
	delete(d.hook_req)
	for m in d.modes do delete(m)
	delete(d.modes)
	free(d)
	if len(h.dialogs) == 0 && h.state == "awaiting_input" do set_state(h.state_before_dialog == "idle" ? "idle" : "busy")
}

cancel_open_dialogs :: proc() {
	h := hub()
	for len(h.dialogs) > 0 {
		d := h.dialogs[0]
		status := "denied"
		switch d.kind {
		case "question", "elicitation": status = "cancelled"
		case "plan": status = "rejected"
		case "terminal": status = "closed"
		}
		close_dialog(d, status, "", "")
	}
}

// Esc on a dialog leaves no PostToolUse, only an error result in the transcript.
@(private = "file")
close_dialogs_from_results :: proc(blocks: string) {
	v, ok := parse_json(blocks)
	if !ok do return
	for block in jarr(v) {
		if jstr(block, "type") != "tool_result" do continue
		d := find_dialog(jstr(block, "tool_use_id"))
		if d == nil do continue
		content := to_json(jget(block, "content"), context.temp_allocator)
		// A permitted command can fail by itself, which isn't a refusal.
		refused := jbool(block, "is_error") && strings.contains(content, "doesn't want to proceed")
		question := d.kind == "question"
		status := refused ? (question ? "cancelled" : "denied") : (question ? "answered" : "allowed")
		close_dialog(d, status, "terminal", "")
	}
}

// The hook process went away without our answer: the person at the terminal
// answered first (Claude Code then stops the hook), or the hook timed out.
hub_client_gone :: proc(cl: ^Client) {
	h := hub()
	for d in h.dialogs {
		if d.hook_client == cl.id {
			d.hook_client = 0
			ev := event("dialog.update")
			jw_str(&ev.w, "id", d.id)
			jw_str(&ev.w, "status", "open")
			jw_bool(&ev.w, "held", false)
			event_send(ev)
		}
	}
	if h.agent_client == cl.id {
		h.agent_client = 0
		ev := event("meta")
		jw_bool(&ev.w, "agent_connected", false)
		event_send(ev)
	}
	if h.waiter_client == cl.id {
		h.waiter_client = 0
		ev := event("meta")
		jw_bool(&ev.w, "hook_waiter_armed", false)
		event_send(ev)
	}
}

// Keys typed at the real terminal. Terminal reports (focus, device attributes)
// aren't keypresses.
hub_on_terminal_input :: proc(bytes: []byte) {
	h := hub()
	if len(bytes) == 0 do return
	is_key := true
	if bytes[0] == 0x1b && len(bytes) > 1 {
		is_key = len(bytes) == 3 && bytes[1] == '[' && (bytes[2] >= 'A' && bytes[2] <= 'D')
	}
	if is_key && len(h.dialogs) > 0 && !h.dialogs[0].touched {
		d := h.dialogs[0]
		d.touched = true
		ev := event("dialog.update")
		jw_str(&ev.w, "id", d.id)
		jw_str(&ev.w, "status", "open")
		jw_bool(&ev.w, "touched", true)
		event_send(ev)
	}
	// A lone Esc, plain or in kitty keyboard encoding, ends a running turn.
	s := string(bytes)
	if s == "\x1b" || s == "\x1b[27u" do on_escape()
}

// Esc ends a running turn. If nothing was produced yet, Claude Code rewinds without
// writing any interrupt marker, so the transcript alone would leave it busy.
on_escape :: proc() {
	h := hub()
	if h.state == "busy" {
		turn_end_begin("interrupted")
		set_state("idle")
		for t in h.pending_tools do pending_tool_free(t)
		clear(&h.pending_tools)
	}
}

// ---------- Transcript ----------

hub_poll_transcript :: proc() {
	h := hub()
	poll_tail(&h.tail, nil)
	poll_agents()
}

// Reads what was appended to a transcript since the last poll: the session's own,
// or a subagent's (`agent` set).
poll_tail :: proc(t: ^Tail, agent: ^Subagent) {
	if t.path == "" do return
	if !t.has_fd {
		fd := c_open(strings.clone_to_cstring(t.path, context.temp_allocator), O_RDONLY | O_CLOEXEC)
		if fd < 0 do return // Claude Code creates it with the first message.
		t.fd, t.has_fd = fd, true
	}
	st: posix.stat_t
	if posix.fstat(posix.FD(t.fd), &st) != .OK do return
	size := i64(st.st_size)
	if size <= t.offset do return
	chunk := make([]u8, size - t.offset, context.temp_allocator)
	got := 0
	for got < len(chunk) {
		n := c_pread(t.fd, raw_data(chunk[got:]), c.size_t(len(chunk)) - c.size_t(got), t.offset + i64(got))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do break
		got += int(n)
	}
	if got == 0 do return
	line_offset := t.offset - i64(len(t.partial))
	t.offset += i64(got)
	data := make([dynamic]u8, 0, len(t.partial) + got, context.temp_allocator)
	append(&data, ..t.partial[:])
	append(&data, ..chunk[:got])
	clear(&t.partial)
	start := 0
	for i in 0 ..< len(data) {
		if data[i] != '\n' do continue
		historic := line_offset + i64(i) < t.catchup_end
		line := string(data[start:i])
		start = i + 1
		if skip_record(line) do continue
		if agent != nil do handle_agent_line(line, agent)
		else do handle_transcript_line(line, historic)
	}
	append(&t.partial, ..data[start:])
}

// Transcript records that are never forwarded, told by the `type` they start with,
// so the large ones (request blobs, data-flow records) are never parsed.
skip_record :: proc(line: string) -> bool {
	PREFIX :: `{"type":"`
	if !strings.has_prefix(line, PREFIX) do return false
	rest := line[len(PREFIX):]
	end := strings.index_byte(rest, '"')
	if end < 0 do return false
	switch rest[:end] {
	case "user", "assistant", "system", "attachment", "cost-state", "repl-mode", "api-request":
		return false
	}
	return true
}

// How often the transcript is read when no hook says something happened: often
// while a turn runs or a prompt is on its way, rarely otherwise. Every hook reads it
// at once anyway.
transcript_interval :: proc() -> i64 {
	h := hub()
	if h.tail.path == "" do return 1000
	if h.state == "busy" || h.state == "awaiting_input" || len(h.in_flight) > 0 || len(h.streams) > 0 || h.turn != nil || len(h.agents) > 0 do return 100
	return 1000
}

@(private = "file")
handle_transcript_line :: proc(line: string, historic: bool) {
	h := hub()
	if enabled, ok := parse_repl_mode(line); ok {
		set_meta_bool("code_mode", &h.code_mode, enabled)
		return
	}
	// Records that aren't conversation, found cheaply before any parse.
	if strings.has_prefix(line, `{"type":"api-request"`) {
		if v, ok := parse_json(line); ok do note_request(jstr(v, "id"), jstr(v, "querySource"))
		return
	}
	if strings.contains(line, `"cost-state"`) {
		if v, ok := parse_json(line); ok && jstr(v, "type") == "cost-state" {
			#partial switch cost in jget(v, "totalCostUSD") {
			case json.Float: set_meta_raw("cost_usd", &h.cost_usd, fmt.tprintf("%.6f", f64(cost)))
			case json.Integer: set_meta_raw("cost_usd", &h.cost_usd, fmt.tprintf("%d", i64(cost)))
			}
		}
		return
	}
	if !historic && strings.contains(line, `"turn_duration"`) {
		if v, ok := parse_json(line); ok && jstr(v, "subtype") == "turn_duration" && !jbool(v, "isSidechain") {
			duration, _ := jint(v, "durationMs")
			turn_marker(duration)
		}
		return
	}
	if !historic && strings.contains(line, `"api_error"`) {
		if v, ok := parse_json(line); ok && jstr(v, "subtype") == "api_error" && !jbool(v, "isSidechain") {
			api_retry_from_transcript(v)
		}
	}
	entry, ok := parse_line(line)
	if !ok do return
	publish_entry(&entry, historic)
}

// A subagent's conversation, forwarded as entries tagged with the agent and the
// tool call that started it. It changes nothing about the main session's state.
@(private = "file")
handle_agent_line :: proc(line: string, a: ^Subagent) {
	h := hub()
	if strings.has_prefix(line, `{"type":"api-request"`) {
		if v, ok := parse_json(line); ok do note_request(jstr(v, "id"), jstr(v, "querySource"))
		return
	}
	entry, ok := parse_line(line)
	if !ok || entry.uuid in h.seen do return
	h.seen[strings.clone(entry.uuid)] = true
	entry.sidechain = true
	emit_entry(&entry, "", false, nil, a)
}

// Claude Code records each retry it is about to make.
@(private = "file")
api_retry_from_transcript :: proc(v: Value) {
	retry_in, _ := jint(v, "retryInMs")
	attempt, _ := jint(v, "retryAttempt")
	max_retries, _ := jint(v, "maxRetries")
	ev := event("api.retry")
	jw_int(&ev.w, "attempt", attempt)
	jw_int(&ev.w, "max_retries", max_retries)
	jw_int(&ev.w, "retry_in_ms", retry_in)
	if e := jget(v, "error"); e != nil do jw_value(&ev.w, "error", e)
	event_send(ev)
	set_activity("retrying", retry_at = retry_in > 0 ? wall_ms() + retry_in : 0)
}

@(private = "file")
publish_entry :: proc(entry: ^Entry, historic: bool) {
	h := hub()
	if entry.uuid in h.seen do return
	h.seen[strings.clone(entry.uuid)] = true
	if !entry.sidechain && entry.model != "" && entry.model != "<synthetic>" {
		set_meta("model", &h.model, entry.model)
		set_meta("model_pending", &h.model_pending, "")
		set_meta("model_error", &h.model_error, "")
	}
	if !entry.sidechain && entry.role == "assistant" {
		if strings.contains(entry.blocks, "\"name\":\"REPL\"") || strings.contains(entry.blocks, "\"name\":\"Eval\"") {
			set_meta_bool("code_mode", &h.code_mode, true)
		}
	}
	if entry.origin == "command" {
		if effort, ok := parse_effort_output(entry.text); ok do set_meta("effort", &h.effort, effort)
		if model, ok := parse_model_switch_output(entry.text); ok {
			set_meta("model", &h.model, model)
			set_meta("model_pending", &h.model_pending, "")
			set_meta("model_error", &h.model_error, "")
		} else if !historic && h.model_pending != "" {
			if stdout, ok2 := parse_command_stdout(entry.text); ok2 && stdout != "" {
				first := stdout
				if nl := strings.index_byte(stdout, '\n'); nl >= 0 do first = stdout[:nl]
				set_meta("model_pending", &h.model_pending, "")
				set_meta("model_error", &h.model_error, strings.trim_space(first))
			}
		}
	}
	if entry.message_id != "" {
		set_insert(&h.in_transcript, entry.message_id)
		// The transcript is the authority on what is in the conversation, so a message
		// it records always joins the chain, whatever its stream looked like.
		if !entry.sidechain {
			set_insert(&h.main_chain, entry.message_id)
			if shape, has := h.shape_by_message[entry.message_id]; has {
				h.main_shape = shape
				if !h.uses_threads && (h.in_thread_by_msg[entry.message_id] or_else true) == false {
					h.threadless_main = true
				}
			}
		}
		if n, has := h.stream_by_message[entry.message_id]; has {
			ev := event("stream.confirmed")
			jw_int(&ev.w, "stream", i64(n))
			jw_str(&ev.w, "message_id", entry.message_id)
			// The record of the request settles which conversation it belonged to.
			if source, known := h.requests[entry.request_ref]; known {
				main := is_main_query(source)
				jw_bool(&ev.w, "main", main)
				jw_str(&ev.w, "query_source", source)
				if s, live := h.streams[n]; live do s.main = main
			}
			event_send(ev)
		}
	}
	prompt_id := ""
	if !historic {
		if entry.origin == "notification" || entry.origin == "terminal" {
			// By Claude Code's prompt_id when UserPromptSubmit bound it, else by text:
			// prompts queued mid-turn and the rewake hook's come in without that id.
			match := -1
			for p, i in h.in_flight do if match < 0 && p.claude_id != "" && p.claude_id == entry.prompt_ref do match = i
			for p, i in h.in_flight do if match < 0 && prompt_matches(p.text, entry.text) do match = i
			for p, i in h.in_flight {
				if i == match {
					prompt_id = strings.clone(p.id, context.temp_allocator)
					if !entry.sidechain do turn_took_prompt(p.id, entry.prompt_ref)
					prompt_status(p, "received")
					ordered_remove(&h.in_flight, i)
					prompt_free(p)
					entry.origin = "external"
					break
				}
			}
		} else if entry.origin == "command" {
			for p, i in h.in_flight {
				if command_matches(p.text, entry.text) {
					prompt_id = strings.clone(p.id, context.temp_allocator)
					// A command that starts a model turn (a skill, say) is part of it.
					if h.turn != nil && !h.turn.ending && !p.command do append(&h.turn.prompts, strings.clone(p.id))
					if !p.command do prompt_status(p, "received")
					ordered_remove(&h.in_flight, i)
					prompt_free(p)
					break
				}
			}
		}
		if entry.origin == "tool_result" do close_dialogs_from_results(entry.blocks)
		switch entry.origin {
		case "interrupt":
			cancel_open_dialogs()
			for t in h.pending_tools do pending_tool_free(t)
			clear(&h.pending_tools)
			if !entry.sidechain do turn_end_begin("interrupted")
			set_state("idle")
		case "terminal", "external", "notification":
			// A line of the turn in progress (by Claude Code's prompt id) isn't a new one.
			if !entry.sidechain && !in_current_turn(entry.prompt_ref) {
				turn_begin(entry.prompt_ref)
				set_state("busy")
			}
		}
	}
	emit_entry(entry, prompt_id, historic, nil)
}

emit_entry :: proc(entry: ^Entry, prompt_id: string, historic: bool, only: ^Client, agent: ^Subagent = nil) {
	ev := event("entry", only = only)
	jw_str(&ev.w, "uuid", entry.uuid)
	jw_str(&ev.w, "session_id", entry.session_id)
	jw_str(&ev.w, "role", entry.role)
	jw_str(&ev.w, "origin", entry.origin)
	jw_str(&ev.w, "timestamp", entry.timestamp)
	jw_str(&ev.w, "text", entry.text)
	jw_raw(&ev.w, "blocks", entry.blocks)
	if entry.model != "" do jw_str(&ev.w, "model", entry.model)
	if entry.message_id != "" do jw_str(&ev.w, "message_id", entry.message_id)
	if prompt_id != "" do jw_str(&ev.w, "prompt_id", prompt_id)
	if entry.prompt_ref != "" do jw_str(&ev.w, "claude_prompt_id", entry.prompt_ref)
	if source, known := hub().requests[entry.request_ref]; known do jw_str(&ev.w, "query_source", source)
	jw_bool(&ev.w, "sidechain", entry.sidechain)
	if agent != nil {
		jw_str(&ev.w, "agent_id", agent.id)
		if agent.parent != "" do jw_str(&ev.w, "parent_tool_use_id", agent.parent)
	}
	if historic do jw_bool(&ev.w, "historic", true)
	event_send(ev)
}

// Replays the conversation so far to one subscriber, from Claude's own transcript.
replay_history :: proc(cl: ^Client) {
	h := hub()
	if h.tail.path == "" do return
	data, err := os.read_entire_file(h.tail.path, context.temp_allocator)
	if err != nil do return
	limit := min(int(h.tail.offset) - len(h.tail.partial), len(data))
	start := 0
	for i in 0 ..< limit {
		if data[i] != '\n' do continue
		line := string(data[start:i])
		start = i + 1
		entry, ok := parse_line(line)
		if !ok do continue
		emit_entry(&entry, "", true, cl)
	}
}

// ---------- Prompts ----------

@(private = "file")
is_stripped_invisible :: proc(r: rune) -> bool {
	switch r {
	case 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x206F, 0xFE00 ..= 0xFE0F, 0xFEFF, 0xE0000 ..= 0xE007F:
		return true
	}
	return false
}

normalize_prompt :: proc(text: string) -> string {
	unwrapped := unwrap_pasted_content(text)
	s, _ := strings.replace_all(unwrapped, "\r\n", "\n", context.temp_allocator)
	s, _ = strings.replace_all(s, "\r", "\n", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		if !is_stripped_invisible(r) do strings.write_rune(&b, r)
	}
	return strings.trim_space(strings.to_string(b))
}

prompt_matches :: proc(sent, seen: string) -> bool {
	seen_norm := normalize_prompt(strip_image_refs(seen))
	if normalize_prompt(sent) == seen_norm do return true
	t := truncate(sent)
	return t != sent && normalize_prompt(t) == seen_norm
}

// Removes the prompt box's "[Image #N]" placeholders.
strip_image_refs :: proc(text: string) -> string {
	if !strings.contains(text, "[Image #") do return text
	b := strings.builder_make(context.temp_allocator)
	rest := text
	for {
		i := strings.index(rest, "[Image #")
		if i < 0 do break
		end := strings.index_byte(rest[i:], ']')
		if end < 0 do break
		strings.write_string(&b, rest[:i])
		rest = rest[i + end + 1:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

command_matches :: proc(sent, seen: string) -> bool {
	invoked, ok := parse_command_invocation(seen)
	if !ok do return false
	collapse :: proc(s: string) -> string {
		fields := strings.fields(s, context.temp_allocator)
		return strings.join(fields, " ", context.temp_allocator)
	}
	return collapse(sent) == collapse(invoked)
}

prompt_free :: proc(p: ^Prompt) {
	delete(p.claude_id)
	for i in p.images do delete(i)
	delete(p.images)
	delete(p.id)
	delete(p.text)
	delete(p.transport)
	delete(p.status)
	free(p)
}

prompt_status :: proc(p: ^Prompt, status: string, error_text := "") {
	delete(p.status)
	p.status = strings.clone(status)
	if p.command do return
	ev := event("prompt")
	write_prompt(&ev.w, p)
	if error_text != "" do jw_str(&ev.w, "error", error_text)
	event_send(ev)
}

Send_Error :: enum {
	None,
	Empty,
	Bad_Transport,
}

// Delivers a prompt. `inproc` types it into the TUI from inside Claude's process, so
// it is a real user turn. It waits while a dialog is open or the session is still
// starting, instead of typing into a dialog. `hook` hands it to the armed rewake
// waiter, which works without the agent.
hub_send_prompt :: proc(text, transport: string, command := false, images: []string = nil) -> (^Prompt, string) {
	h := hub()
	if strings.trim_space(text) == "" && len(images) == 0 do return nil, "prompt is empty"
	if len(images) > 0 && transport != "inproc" do return nil, "images go with the inproc transport"
	if app.shutdown.stage != .None || app.child_exited do return nil, "the session is shutting down"
	clean: string
	switch transport {
	case "hook":
		// Keep a prompt from closing the reminder Claude Code wraps it in.
		clean, _ = strings.replace_all(text, "</system-reminder>", "&lt;/system-reminder&gt;", context.temp_allocator)
	case "inproc":
		// Control characters could end the bracketed paste and act as keypresses.
		b := strings.builder_make(context.temp_allocator)
		for r in text {
			if r < 0x20 && r != '\n' && r != '\t' do continue
			if r == 0x7f do continue
			strings.write_rune(&b, r)
		}
		clean = strings.to_string(b)
	case:
		return nil, fmt.tprintf("unknown transport %q, expected \"inproc\" or \"hook\"", transport)
	}
	h.next_prompt += 1
	p := new(Prompt)
	p.id = fmt.aprintf("p%d", h.next_prompt)
	p.text = strings.clone(clean)
	p.transport = strings.clone(transport)
	p.status = strings.clone("queued")
	p.command = command
	for i in images do append(&p.images, strings.clone(i))
	if transport == "hook" {
		append(&h.hook_queue, p)
		prompt_status(p, "queued")
		hook_waiter_deliver()
	} else {
		append(&h.inproc_queue, p)
		prompt_status(p, "queued")
		flush_inproc_queue()
	}
	return p, ""
}

can_type_prompt :: proc() -> bool {
	h := hub()
	return h.session_started && len(h.dialogs) == 0 && h.state != "awaiting_input" && h.mode_task == nil && !app.child_exited && app.shutdown.stage == .None && !settling() && !card_on_screen(app.screen) && !draft_in_the_way()
}

// A draft in the prompt box holds zclaude's typing until it is sent or cleared. A
// draft zclaude typed itself (a prompt waiting for its Enter) holds the next one too.
draft_in_the_way :: proc() -> bool {
	return composer_draft(app.screen)
}

flush_inproc_queue :: proc() {
	h := hub()
	for len(h.inproc_queue) > 0 && can_type_prompt() {
		p := h.inproc_queue[0]
		ordered_remove(&h.inproc_queue, 0)
		append(&h.in_flight, p)
		feed_prompt(p.text, p.images[:])
		prompt_status(p, "delivered")
	}
}

input_route :: proc() -> Input_Route {
	return agent() != nil ? .Agent : .Pty
}

send_input :: proc(route: Input_Route, data: []byte) {
	if route == .Agent {
		if a := agent(); a != nil {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "{\"method\":\"agent.input\",\"params\":{\"data\":\"")
			strings.write_string(&b, base64.encode(data, allocator = context.temp_allocator))
			strings.write_string(&b, "\"}}\n")
			client_send(a, strings.to_string(b))
			return
		}
	}
	pty_write(data)
}

@(private = "file")
feed_prompt :: proc(text: string, images: []string) {
	h := hub()
	h.prompt_submitted = false
	h.feed_gen += 1
	// A retried Enter is only safe where it can't do anything else. During a turn the
	// prompt is queued with no hook to confirm it, and a slash command may open a
	// menu where Enter would pick an option.
	retry := h.state == "idle" && !strings.has_prefix(strings.trim_left_space(text), "/")
	route := input_route()
	// An image goes in the way a terminal drops a file: its path, pasted on its own,
	// which the prompt box turns into [Image #N]. Each gets a moment to load.
	at: i64 = 0
	pastes := make([dynamic]string, context.temp_allocator)
	for path in images do append(&pastes, paste_path(path))
	if strings.trim_space(text) != "" do append(&pastes, text)
	for paste, i in pastes {
		data := fmt.tprintf("\x1b[200~%s\x1b[201~", paste)
		if i == 0 do send_input(route, transmute([]u8)data)
		else do timer_add(at, .Input, data, route)
		at += i < len(images) ? IMAGE_PASTE_MS : 0
	}
	// Enter must arrive separately, or the TUI treats it as part of the paste.
	timer_add(at + KEY_DELAY_MS, .Enter, "", route, 0, h.feed_gen)
	if retry do timer_add(at + KEY_DELAY_MS + ENTER_RETRY_MS, .Enter_Retry, "", route, 1, h.feed_gen)
}

IMAGE_PASTE_MS :: 250

// A path as the prompt box recognizes it: bare, or single-quoted if it needs to be.
@(private = "file")
paste_path :: proc(path: string) -> string {
	plain := true
	for c in transmute([]u8)path {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '.' || c == '_' || c == '-'
		if !ok do plain = false
	}
	if plain do return path
	escaped, _ := strings.replace_all(path, "'", "'\\''", context.temp_allocator)
	return fmt.tprintf("'%s'", escaped)
}

// How long a prompt's Enter waits for a card that opened under it.
ENTER_HOLD_MS :: 60_000
ENTER_HOLD_STEP_MS :: 100

// The rewake waiter: a hook process that blocks until a prompt arrives.
hub_on_hook_wait :: proc(cl: ^Client, req_id: string) {
	h := hub()
	if h.waiter_client != 0 && client_by_id(h.waiter_client) != nil {
		reply_result(cl, req_id, "{\"action\":\"exit\"}")
		return
	}
	cl.kind = .Hook_Wait
	delete(cl.held_id)
	cl.held_id = strings.clone(req_id)
	h.waiter_client = cl.id
	ev := event("meta")
	jw_bool(&ev.w, "hook_waiter_armed", true)
	event_send(ev)
	hook_waiter_deliver()
}

@(private = "file")
hook_waiter_deliver :: proc() {
	h := hub()
	if len(h.hook_queue) == 0 || h.waiter_client == 0 do return
	cl := client_by_id(h.waiter_client)
	if cl == nil do return
	p := h.hook_queue[0]
	ordered_remove(&h.hook_queue, 0)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"action\":\"deliver\",\"text\":")
	write_quoted(&b, p.text)
	strings.write_string(&b, "}")
	reply_result(cl, cl.held_id, strings.to_string(b))
	h.waiter_client = 0
	append(&h.in_flight, p)
	prompt_status(p, "delivered")
}

// ---------- Streams ----------

hub_on_stream_event :: proc(e: Value) {
	h := hub()
	n64, ok := jint(e, "stream")
	if !ok do return
	n := int(n64)
	s, exists := h.streams[n]
	if !exists {
		s = new(Live_Stream)
		s.n = n
		s.status = strings.clone("streaming")
		s.started_at = wall_ms()
		h.streams[n] = s
	}
	switch jstr(e, "type") {
	case "message_start":
		id := jstr(e, "message_id")
		model := jstr(e, "model")
		delete(s.message_id)
		delete(s.model)
		s.message_id = strings.clone(id)
		s.model = strings.clone(model)
		// Forks and title calls aren't in a thread at all. A subagent has a chain of its
		// own, and the main conversation opens fresh threads too, after an interrupt or a
		// subagent. Those are told apart by the request's shape. Builds or providers
		// without `thread` fall back to shape matching once the transcript confirms the
		// first main message came without `thread`.
		in_thread := jbool(e, "in_thread")
		if in_thread {
			h.uses_threads = true
			h.threadless_main = false
		}
		previous := jstr(e, "previous_message_id")
		shape: Maybe(Shape)
		if tools := jstr(e, "shape", "tools"); tools != "" {
			shape = Shape{tools = tools, system = jstr(e, "shape", "system")}
		}
		continues := previous != "" && previous in h.main_chain
		matches_shape := false
		if sh, has := shape.?; has {
			if known, has_known := h.main_shape.?; has_known {
				matches_shape = sh.tools == known.tools || sh.system == known.system
			}
		}
		restarts := previous == "" && matches_shape
		first := len(h.main_chain) == 0 && h.main_shape == nil
		cache_read, _ := jint(e, "cache_read_tokens")
		cache_write, _ := jint(e, "cache_write_tokens")
		is_cache_fork := cache_read > 0 && cache_write == 0
		main := false
		if in_thread {
			main = first || continues || restarts
		} else if !h.uses_threads && h.threadless_main {
			main = !is_cache_fork && matches_shape
		}
		s.main = main
		if main {
			set_insert(&h.main_chain, id)
			if sh, has := shape.?; has do h.main_shape = clone_shape(sh)
			if model != "" {
				set_meta("model", &h.model, model)
				set_meta("model_pending", &h.model_pending, "")
				set_meta("model_error", &h.model_error, "")
			}
			if cm, is_bool := jget(e, "code_mode").(json.Boolean); is_bool do set_meta_bool("code_mode", &h.code_mode, bool(cm))
		}
		s.usage.input, _ = jint(e, "input_tokens")
		s.usage.output, _ = jint(e, "output_tokens")
		s.usage.cache_read = cache_read
		s.usage.cache_write = cache_write
		if main {
			turn_begin()
			set_activity("requesting")
		}
		if id != "" {
			if id not_in h.in_thread_by_msg do h.in_thread_by_msg[strings.clone(id)] = in_thread
			if sh, has := shape.?; has {
				if !in_thread && !h.uses_threads && id in h.main_chain {
					h.main_shape = clone_shape(sh)
					h.threadless_main = true
				}
				if id not_in h.shape_by_message do h.shape_by_message[strings.clone(id)] = clone_shape(sh)
			}
			if id not_in h.stream_by_message do h.stream_by_message[strings.clone(id)] = n
		}
		ev := event("stream.start")
		jw_int(&ev.w, "stream", i64(n))
		jw_str(&ev.w, "message_id", id)
		jw_str(&ev.w, "model", model)
		jw_bool(&ev.w, "main", main)
		jw_bool(&ev.w, "in_thread", in_thread)
		if previous != "" do jw_str(&ev.w, "previous_message_id", previous)
		jw_bool(&ev.w, "in_transcript", id != "" && id in h.in_transcript)
		jw_int(&ev.w, "started_at", s.started_at)
		write_usage(&ev.w, "usage", s.usage)
		event_send(ev)
	case "content_block_start":
		index, _ := jint(e, "index")
		b := new(Live_Block)
		b.index = int(index)
		b.type = strings.clone(jstr(e, "block_type"))
		b.name = strings.clone(jstr(e, "tool"))
		b.text = strings.builder_make()
		b.started_at = wall_ms()
		append(&s.blocks, b)
		if s.main {
			switch b.type {
			case "thinking", "redacted_thinking": set_activity("thinking")
			case "text": set_activity("responding")
			case "tool_use", "server_tool_use": set_activity("calling", b.name)
			}
		}
		ev := event("stream.block")
		jw_int(&ev.w, "stream", i64(n))
		jw_int(&ev.w, "index", index)
		jw_str(&ev.w, "type", b.type)
		if b.name != "" do jw_str(&ev.w, "name", b.name)
		jw_int(&ev.w, "started_at", b.started_at)
		event_send(ev)
	case "content_block_delta":
		index, _ := jint(e, "index")
		text := jstr(e, "text")
		if text == "" do return
		for b in s.blocks {
			if b.index == int(index) {
				strings.write_string(&b.text, text)
				break
			}
		}
		ev := event("stream.delta")
		jw_int(&ev.w, "stream", i64(n))
		jw_int(&ev.w, "index", index)
		jw_str(&ev.w, "text", text)
		event_send(ev)
	case "content_block_stop":
		index, _ := jint(e, "index")
		ended := wall_ms()
		for b in s.blocks {
			if b.index == int(index) do b.ended_at = ended
		}
		ev := event("stream.block_stop")
		jw_int(&ev.w, "stream", i64(n))
		jw_int(&ev.w, "index", index)
		jw_int(&ev.w, "ended_at", ended)
		event_send(ev)
	case "message_delta":
		if out, has_out := jint(e, "output_tokens"); has_out {
			s.usage.output = max(s.usage.output, out)
			ev := event("stream.usage")
			jw_int(&ev.w, "stream", i64(n))
			write_usage(&ev.w, "usage", s.usage)
			event_send(ev)
		}
		if reason := jstr(e, "stop_reason"); reason != "" {
			delete(s.stop_reason)
			s.stop_reason = strings.clone(reason)
			ev := event("stream.stop_reason")
			jw_int(&ev.w, "stream", i64(n))
			jw_str(&ev.w, "stop_reason", reason)
			event_send(ev)
		}
	case "message_stop":
		end_stream(s, "done")
		turn_add_message(s)
	case "stream_end":
		if !jbool(e, "stopped") do end_stream(s, "aborted")
		turn_add_message(s)
		delete_key(&h.streams, n)
		stream_free(s)
	}
}

@(private = "file")
clone_shape :: proc(s: Shape) -> Shape {
	return Shape{tools = strings.clone(s.tools), system = strings.clone(s.system)}
}

@(private = "file")
end_stream :: proc(s: ^Live_Stream, status: string) {
	if s.status != "streaming" do return
	delete(s.status)
	s.status = strings.clone(status)
	ev := event("stream.end")
	jw_int(&ev.w, "stream", i64(s.n))
	jw_str(&ev.w, "status", status)
	jw_int(&ev.w, "ended_at", wall_ms())
	event_send(ev)
}

@(private = "file")
stream_free :: proc(s: ^Live_Stream) {
	for b in s.blocks {
		delete(b.type)
		delete(b.name)
		strings.builder_destroy(&b.text)
		free(b)
	}
	delete(s.blocks)
	delete(s.message_id)
	delete(s.model)
	delete(s.status)
	delete(s.stop_reason)
	free(s)
}

// ---------- Agent ----------

hub_on_agent_hello :: proc(cl: ^Client, params: Value) {
	h := hub()
	cl.kind = .Agent
	h.agent_client = cl.id
	ev := event("meta")
	jw_bool(&ev.w, "agent_connected", true)
	event_send(ev)
	if cm, ok := jget(params, "code_mode").(json.Boolean); ok do set_meta_bool("code_mode", &h.code_mode, bool(cm))
}

hub_on_agent_reply :: proc(params: Value) {
	h := hub()
	id, ok := jint(params, "request")
	if !ok do return
	req, has := h.memory_requests[int(id)]
	if !has do return
	delete_key(&h.memory_requests, int(id))
	if cl := client_by_id(req.client_id); cl != nil {
		reply_result(cl, req.req_id, to_json(jget(params, "result"), context.temp_allocator))
	}
	delete(req.req_id)
}

// ---------- Timers, screen, lifecycle ----------

hub_on_timer :: proc(t: Timer) {
	h := hub()
	switch t.kind {
	case .Input:
		send_input(t.route, transmute([]u8)t.data)
	case .Enter:
		// A card that opened between the paste and its Enter would take the Enter as
		// "Yes". It waits until the card has gone, and the draft is sent then.
		if t.gen != h.feed_gen do return
		if len(h.dialogs) > 0 || settling() || card_on_screen(app.screen) {
			if t.n * ENTER_HOLD_STEP_MS < ENTER_HOLD_MS do timer_add(ENTER_HOLD_STEP_MS, .Enter, "", t.route, t.n + 1, t.gen)
			return
		}
		send_input(t.route, transmute([]u8)string("\r"))
	case .Enter_Retry:
		// UserPromptSubmit comes before anything that could open a dialog, so once it
		// is seen no further Enter is sent that could answer one.
		if h.prompt_submitted || t.gen != h.feed_gen || len(h.dialogs) > 0 || card_on_screen(app.screen) do return
		send_input(t.route, transmute([]u8)string("\r"))
		if t.n < ENTER_RETRIES do timer_add(ENTER_RETRY_MS, .Enter_Retry, "", t.route, t.n + 1, t.gen)
	case .Mode_Step:
		mode_step()
	case .Settle:
		// Nothing to do: the loop woke, and the next tick types what was held.
	case .Shutdown:
		shutdown_step()
	case .Turn_End:
		turn_timer(t.n)
	case .Agent_Drain:
		agent_drain(t.n)
	case .Task_Step:
		task_stop_step()
	case .Effort_Step:
		effort_step()
	case .Memory_Timeout:
		if req, has := h.memory_requests[t.n]; has {
			delete_key(&h.memory_requests, t.n)
			if cl := client_by_id(req.client_id); cl != nil do reply_error(cl, req.req_id, "the agent did not reply")
			delete(req.req_id)
		}
	}
}

hub_on_screen_change :: proc() {
	hub().screen_dirty = true
}

hub_after_tick :: proc() {
	h := hub()
	flush_inproc_queue()
	// Which sources are live: Claude Code's hooks, the agent inside its process, its
	// status line and its transcript. A consumer sees at once if one has stopped.
	sources := fmt.tprintf(`{{"hooks":%v,"agent":%v,"status_line":%v,"transcript":%v}}`, h.session_started, h.agent_client != 0, h.status_seq > 0, h.tail.has_fd)
	if sources != h.sources do set_meta_raw("sources", &h.sources, sources)
	if h.screen_dirty && now_ms() - h.screen_checked_at >= SCREEN_CHECK_MS {
		h.screen_dirty = false
		h.screen_checked_at = now_ms()
		if mode, ok := detect_mode(app.screen); ok && len(h.dialogs) == 0 {
			set_meta("permission_mode", &h.permission_mode, mode)
		}
		for d in h.dialogs {
			if d.kind != "plan" || len(d.modes) > 0 do continue
			learn_plan_modes(d)
			// Still being drawn: look again. A card that offers no approve choice
			// (an empty plan) never gets any, so this stops after a while.
			if len(d.modes) == 0 && wall_ms() - d.created_at < PLAN_MODES_WAIT_MS do h.screen_dirty = true
		}
		sync_terminal_card()
		sync_retry()
	}
}

// A card has to stay up this long before it is reported without a hook behind it,
// so the hook that usually comes with a card wins the race to describe it.
CARD_GRACE_MS :: 600
PLAN_MODES_WAIT_MS :: 5000

// Reports selection cards that no hook told zclaude about (a model picker, a card
// whose hook timed out, anything new) as `terminal` dialogs, so a consumer always
// sees what the terminal is waiting for and can answer it by choice number.
@(private = "file")
sync_terminal_card :: proc() {
	h := hub()
	term: ^Dialog
	hooked := false
	for d in h.dialogs {
		if d.kind == "terminal" do term = d
		else do hooked = true
	}
	menu := screen_menu(app.screen)
	up := card_in(menu, app.screen)
	if !up {
		h.card_since = 0
		if st, ok := h.settle.?; ok && st.kind == "terminal" do settle_end()
		if term != nil do close_dialog(term, "closed", "terminal", "")
		return
	}
	// zclaude's own steps through a menu (effort, tasks) aren't questions for anyone.
	if hooked || settling() || h.effort_task != nil || h.task_stop != nil {
		h.card_since = 0
		if term != nil do close_dialog(term, "closed", "", "")
		return
	}
	if term != nil {
		// Another card replaced this one. Moving the highlight changes nothing.
		if !same_options(term, menu) do close_dialog(term, "closed", "terminal", "")
		else do return
	}
	text := card_text(app.screen)
	now := now_ms()
	if h.card_since == 0 do h.card_since = now
	if now - h.card_since < CARD_GRACE_MS {
		h.screen_dirty = true // look again on the next check
		return
	}
	h.next_dialog += 1
	open_dialog(nil, "", fmt.tprintf("term-%d", h.next_dialog), "terminal", "", card_input(menu, text), "")
}

@(private = "file")
same_options :: proc(d: ^Dialog, menu: Menu) -> bool {
	v, _ := parse_json(d.input)
	shown := jarr(v, "options")
	if len(shown) != len(menu.labels) do return false
	for o, i in shown do if jstr(o) != menu.labels[i] do return false
	return true
}

@(private = "file")
card_input :: proc(menu: Menu, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := jw_make(&b)
	jw_obj(&w)
	jw_str(&w, "text", text)
	jw_arr_key(&w, "options")
	for l in menu.labels do jw_str_item(&w, l)
	jw_end_arr(&w)
	jw_end_obj(&w)
	return strings.to_string(b)
}

// The card's lines: from the rule drawn above it to the bottom of the screen.
@(private = "file")
card_text :: proc(s: ^Screen) -> string {
	lines := screen_lines(s)
	end := len(lines)
	for end > 0 && strings.trim_space(lines[end - 1]) == "" do end -= 1
	start := 0
	for i := end - 1; i >= 0; i -= 1 {
		if is_rule(lines[i]) {
			start = i + 1
			break
		}
	}
	kept := make([dynamic]string, context.temp_allocator)
	for l in lines[start:end] do append(&kept, strings.trim_right_space(l))
	return strings.trim_space(strings.join(kept[:], "\n", context.temp_allocator))
}

// A line drawn across the screen, as Claude Code separates its cards: box-drawing
// or block characters (─ ━ ╌ ▔ ▁ …) and nothing else.
@(private = "file")
is_rule :: proc(line: string) -> bool {
	n := 0
	for r in strings.trim_space(line) {
		if r < 0x2500 || r > 0x259F do return false
		n += 1
	}
	return n >= 10
}

// Answers whatever card is on screen by its choice number, the way a person
// would: arrows to the choice, any text into its field, then Enter. `0` is Esc.
answer_card :: proc(option: int, text: string, final := "\r") -> string {
	menu := screen_menu(app.screen)
	if !card_in(menu, app.screen) do return "no card is on the terminal screen"
	if option < 0 || option > len(menu.labels) do return fmt.tprintf("option must be 1 to %d, or 0 for Esc", len(menu.labels))
	steps := make([dynamic]string, context.temp_allocator)
	if option == 0 {
		append(&steps, "\x1b")
	} else {
		delta := (option - 1) - max(menu.cursor, 0)
		key, _ := key_bytes(delta < 0 ? "up" : "down")
		for _ in 0 ..< abs(delta) do append(&steps, key)
		if text != "" do append(&steps, fmt.tprintf("\x1b[200~%s\x1b[201~", text))
		append(&steps, final)
	}
	for step, i in steps {
		if i == 0 do pty_write(transmute([]u8)step)
		else do timer_add(i64(i) * 60, .Input, step, .Pty)
	}
	return ""
}

// Reads the approve choices off the plan card once it is drawn. Claude Code builds
// them from what this session allows (auto mode, bypass), so they differ between
// sessions and versions.
@(private = "file")
learn_plan_modes :: proc(d: ^Dialog) {
	modes := plan_modes_on_screen(app.screen)
	if len(modes) == 0 do return
	for m in modes do append(&d.modes, strings.clone(m))
	ev := event("dialog.update")
	jw_str(&ev.w, "id", d.id)
	jw_str(&ev.w, "status", "open")
	write_modes(&ev.w, d)
	event_send(ev)
}

// A selection card as Claude Code draws it, e.g. "❯ 1. Yes" over "  2. No".
Menu :: struct {
	labels: []string,
	cursor: int, // the highlighted choice, -1 if none
}

// The numbered choices on the screen. Lines between numbers (descriptions, wrapped
// labels) are skipped. The last list that counts up from 1 wins, so numbered lines
// in a plan above the card don't.
screen_menu :: proc(s: ^Screen) -> Menu {
	labels := make([dynamic]string, context.temp_allocator)
	cursor := -1
	for raw in screen_lines(s) {
		line := strings.trim_space(raw)
		marked := strings.has_prefix(line, "❯")
		line = strings.trim_left_space(strings.trim_prefix(line, "❯"))
		dot := strings.index_byte(line, '.')
		if dot <= 0 || dot > 2 || dot + 1 >= len(line) || line[dot + 1] != ' ' do continue
		n := 0
		digits := true
		for c in transmute([]u8)line[:dot] {
			if c < '0' || c > '9' do digits = false
			else do n = n * 10 + int(c - '0')
		}
		if !digits do continue
		label := strings.trim_space(line[dot + 1:])
		// A second column (a model's description, say) starts after a run of spaces.
		if gap := strings.index(label, "   "); gap > 0 do label = label[:gap]
		if n == 1 {
			clear(&labels)
			cursor = -1
			append(&labels, label)
		} else if n == len(labels) + 1 {
			append(&labels, label)
		} else {
			continue
		}
		if marked do cursor = n - 1
	}
	return Menu{labels = labels[:], cursor = cursor}
}

// Whether a selection card is up in the terminal, whether or not a hook told
// zclaude about it. Enter there picks the highlighted choice, so nothing is typed
// while one is up. A card replaces the prompt box and its mode footer; a draft in
// the prompt box that happens to look like a list keeps the footer.
card_on_screen :: proc(s: ^Screen) -> bool {
	return card_in(screen_menu(s), s)
}

card_in :: proc(menu: Menu, s: ^Screen) -> bool {
	if len(menu.labels) < 2 || menu.cursor < 0 do return false
	_, footer := detect_mode(s)
	return !footer
}

plan_modes_on_screen :: proc(s: ^Screen) -> []string {
	modes := make([dynamic]string, context.temp_allocator)
	for label in screen_menu(s).labels {
		l := strings.to_lower(label, context.temp_allocator)
		mode := ""
		switch {
		// Clearing the context starts a new conversation, which a hook can't ask for.
		case strings.contains(l, "clear context"):
		case strings.contains(l, "bypass permissions"): mode = "bypassPermissions"
		case strings.contains(l, "auto mode"): mode = "auto"
		case strings.contains(l, "accept edits") || strings.contains(l, "auto-accept"): mode = "acceptEdits"
		case strings.contains(l, "manually approve"): mode = "default"
		}
		if mode == "" do continue
		seen := false
		for m in modes do if m == mode do seen = true
		if !seen do append(&modes, mode)
	}
	return modes[:]
}

hub_stdio_closed :: proc() {
	// The consumer that owns a headless session has gone, so end it.
	begin_shutdown()
}

// ---------- Shutdown ----------

// Ending a session the way a person would: the turn is stopped, cards are refused,
// and /exit is typed, so Claude Code runs its SessionEnd hooks, saves its state and
// exits 0. SIGHUP follows if that hasn't worked in SHUTDOWN_GRACE_MS, and SIGKILL
// SHUTDOWN_KILL_MS later. Asking again skips ahead one stage.
SHUTDOWN_GRACE_MS :: 6000
SHUTDOWN_KILL_MS :: 4000
SHUTDOWN_STEP_MS :: 100

begin_shutdown :: proc(force := false) -> string {
	h := hub()
	if app.child_exited || app.child_pid <= 0 do return "exited"
	sd := &app.shutdown
	switch sd.stage {
	case .None:
		// Prompts nobody has typed yet will never be.
		for list in ([]^[dynamic]^Prompt{&h.inproc_queue, &h.hook_queue}) {
			for p in list^ {
				prompt_status(p, "failed", "the session is shutting down")
				prompt_free(p)
			}
			clear(list)
		}
		if force {
			shutdown_hangup()
		} else {
			sd.stage = .Graceful
			sd.hup_at = now_ms() + SHUTDOWN_GRACE_MS
			shutdown_step()
		}
	case .Graceful:
		shutdown_hangup()
	case .Hangup, .Killed:
		shutdown_kill()
	}
	#partial switch sd.stage {
	case .Graceful: return "graceful"
	case .Hangup: return "hangup"
	}
	return "kill"
}

@(private = "file")
shutdown_hangup :: proc() {
	sd := &app.shutdown
	sd.stage = .Hangup
	sd.kill_at = now_ms() + SHUTDOWN_KILL_MS
	if !app.child_exited do c_kill(app.child_pid, SIGHUP)
	timer_add(SHUTDOWN_KILL_MS, .Shutdown)
}

@(private = "file")
shutdown_kill :: proc() {
	app.shutdown.stage = .Killed
	if app.child_exited do return
	// Claude's process group is the terminal's foreground job: Claude itself, under
	// the `__session` job-control process in interactive mode, and anything it
	// started there that never left the group.
	if app.pty_fd >= 0 {
		if pg := c_tcgetpgrp(app.pty_fd); pg > 1 do c_kill(-pg, SIGKILL)
	}
	c_kill(app.child_pid, SIGKILL)
}

shutdown_step :: proc() {
	h := hub()
	sd := &app.shutdown
	if app.child_exited do return
	now := now_ms()
	switch sd.stage {
	case .None, .Killed:
		return
	case .Hangup:
		if now >= sd.kill_at do shutdown_kill()
		return
	case .Graceful:
	}
	if now >= sd.hup_at {
		shutdown_hangup()
		return
	}
	defer timer_add(SHUTDOWN_STEP_MS, .Shutdown)
	if !h.session_started do return
	if len(h.dialogs) > 0 {
		held := false
		for d in h.dialogs do if d.hook_client != 0 do held = true
		if held {
			rpc_interrupt()
		} else if now - sd.esc_at > 500 {
			// A card only the terminal can answer: Esc refuses it.
			send_input(input_route(), transmute([]u8)string("\x1b"))
			sd.esc_at = now
		}
		return
	}
	if settling() do return
	// A card zclaude has no hook for (or whose hook has gone): Enter would answer it,
	// so it is refused with Esc first.
	if card_on_screen(app.screen) || h.state == "awaiting_input" {
		if now - sd.esc_at > 500 {
			send_input(input_route(), transmute([]u8)string("\x1b"))
			sd.esc_at = now
		}
		return
	}
	if h.state == "busy" {
		if sd.esc_at == 0 {
			send_input(input_route(), transmute([]u8)string("\x1b"))
			sd.esc_at = now
		}
		// Claude Code takes a moment to wind a turn down after Esc.
		if now - sd.esc_at < 400 do return
	}
	// Typed once, and again if the first was swallowed (by a menu, say).
	if sd.exits == 0 || (sd.exits == 1 && now - sd.exit_at > 2500) {
		route := input_route()
		// Ctrl+U clears a draft, which would otherwise be sent ahead of /exit.
		send_input(route, transmute([]u8)string("\x15\x1b[200~/exit\x1b[201~"))
		timer_add(KEY_DELAY_MS, .Input, "\r", route)
		sd.exits += 1
		sd.exit_at = now
	}
}

hub_on_child_exit :: proc(code: int, signal := 0) {
	h := hub()
	app.child_exited = true
	app.exit_code = code
	app.exit_signal = signal
	h.exited_code = code
	hub_poll_transcript()
	cancel_open_dialogs()
	agents_drain_all()
	if h.turn != nil {
		if !h.turn.ending do turn_end_begin("exited")
		turn_finish()
	}
	set_state("exited")
}

hub_on_exit :: proc() {
	// Everyone who asked the session for anything hears how it ended, subscribed or not.
	for cl in app.clients do if cl.kind == .Control do cl.subscribed = true
	ev := event("exit")
	jw_int(&ev.w, "code", i64(app.exit_code))
	if app.exit_signal != 0 do jw_str(&ev.w, "signal", signal_name(app.exit_signal))
	event_send(ev)
}

signal_name :: proc(sig: int) -> string {
	switch c.int(sig) {
	case SIGHUP: return "SIGHUP"
	case SIGINT: return "SIGINT"
	case SIGKILL: return "SIGKILL"
	case SIGPIPE: return "SIGPIPE"
	case SIGTERM: return "SIGTERM"
	}
	return fmt.tprintf("signal %d", sig)
}

// The permission mode as the footer shows it, e.g. "⏵⏵ accept edits on (shift+tab to
// cycle)". Only trusted while the footer is visible.
detect_mode :: proc(s: ^Screen) -> (string, bool) {
	// Claude Code's indicators, each shown as "<indicator> on" (zr in its source).
	INDICATORS :: [][2]string {
		{"manualmodeon", "default"},
		{"accepteditson", "acceptEdits"},
		{"planmodeon", "plan"},
		{"bypasspermissionson", "bypassPermissions"},
		{"automodeon", "auto"},
		{"don'taskon", "dontAsk"},
	}
	lines := screen_lines(s)
	from := max(len(lines) - 8, 0)
	for i := len(lines) - 1; i >= from; i -= 1 {
		line := strings.to_lower(lines[i], context.temp_allocator)
		compact, _ := strings.remove_all(line, " ", context.temp_allocator)
		compact, _ = strings.remove_all(compact, "\u2019", context.temp_allocator) // a curly apostrophe
		for ind in INDICATORS do if strings.contains(compact, ind[0]) do return ind[1], true
		// Older builds show only the hint in the default mode.
		if strings.contains(compact, "?forshortcuts") do return "default", true
		// The footer's hint is "(shift+tab to cycle)"; a card's "shift+tab to approve
		// with this feedback" isn't a footer.
		if strings.contains(compact, "shift+tabtocycle") {
			switch {
			case strings.contains(compact, "acceptedits"): return "acceptEdits", true
			case strings.contains(compact, "planmode"): return "plan", true
			case strings.contains(compact, "bypasspermissions"): return "bypassPermissions", true
			case strings.contains(compact, "automode"): return "auto", true
			case strings.contains(compact, "dontask"): return "dontAsk", true
			}
			return "default", true
		}
	}
	return "", false
}

hub_set_mode :: proc(cl: ^Client, req_id, target: string) -> string {
	h := hub()
	switch target {
	case "default", "acceptEdits", "plan", "bypassPermissions", "auto", "dontAsk":
	case:
		return fmt.tprintf("unknown mode %q, expected default, acceptEdits, plan, auto, dontAsk or bypassPermissions", target)
	}
	if !h.session_started do return "the session has not started yet"
	if len(h.dialogs) > 0 do return "a dialog is open; answer it first"
	if h.mode_task != nil do return "a mode change is already running"
	t := new(Mode_Task)
	t.client_id = cl.id
	t.req_id = strings.clone(req_id)
	t.target = strings.clone(target)
	h.mode_task = t
	mode_step()
	return ""
}

@(private = "file")
mode_step :: proc() {
	h := hub()
	t := h.mode_task
	if t == nil do return
	// Shift+Tab on a card that is still closing would answer it (on a plan card it
	// approves with feedback), so wait for it to go.
	if settling() || card_on_screen(app.screen) {
		if t.waits < 60 {
			t.waits += 1
			timer_add(100, .Mode_Step)
			return
		}
	}
	finish :: proc(t: ^Mode_Task, err: string, mode: string) {
		h := hub()
		if cl := client_by_id(t.client_id); cl != nil {
			if err != "" {
				reply_error(cl, t.req_id, err)
			} else {
				reply_result(cl, t.req_id, fmt.tprintf("{{\"mode\":\"%s\"}}", mode))
			}
		}
		delete(t.req_id)
		delete(t.target)
		for s in t.seen do delete(s)
		delete(t.seen)
		free(t)
		h.mode_task = nil
	}
	mode, ok := detect_mode(app.screen)
	if ok {
		set_meta("permission_mode", &h.permission_mode, mode)
		if mode == t.target {
			finish(t, "", mode)
			return
		}
		seen := false
		for s in t.seen do if s == mode do seen = true
		if !seen do append(&t.seen, strings.clone(mode))
	}
	if t.attempts >= 8 || len(h.dialogs) > 0 {
		finish(t, fmt.tprintf("could not reach %s by cycling with Shift+Tab (saw: %s)", t.target, strings.join(t.seen[:], ", ", context.temp_allocator)), "")
		return
	}
	if card_on_screen(app.screen) {
		finish(t, "a dialog is on the terminal screen; answer it first", "")
		return
	}
	t.attempts += 1
	pty_write(transmute([]u8)string("\x1b[Z"))
	timer_add(350, .Mode_Step)
}

hub_memory :: proc(cl: ^Client, req_id: string) -> string {
	h := hub()
	a := agent()
	if a == nil do return "the in-process agent is not connected"
	h.next_request += 1
	n := h.next_request
	h.memory_requests[n] = Memory_Request{client_id = cl.id, req_id = strings.clone(req_id)}
	client_send(a, fmt.tprintf("{{\"method\":\"agent.memory\",\"params\":{{\"request\":%d}}}}\n", n))
	timer_add(5000, .Memory_Timeout, "", .Pty, n)
	return ""
}
