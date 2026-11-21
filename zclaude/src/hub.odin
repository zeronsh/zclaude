package zclaude

// Session state and the events it produces. Nothing here is stored for later: the
// hub keeps only what it needs to act correctly (open dialogs, prompts in flight,
// streams still receiving tokens), and forwards everything else as it happens.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

KEY_DELAY_MS :: 120
ENTER_RETRY_MS :: 1000
ENTER_RETRIES :: 3

Prompt :: struct {
	id:        string,
	text:      string,
	transport: string, // inproc | hook
	status:    string, // queued | delivered | received | failed
	command:   bool,   // sent by zclaude itself (model switch), not shown as a prompt
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
}

Tail :: struct {
	path:        string,
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
	h.state = state
	ev := event("state")
	jw_str(&ev.w, "state", state)
	jw_str(&ev.w, "previous", previous)
	event_send(ev)
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
@(private = "file")
hook_common :: proc(params: Value) {
	h := hub()
	if jhas(params, "agent_id") do return
	if path := jstr(params, "transcript_path"); path != "" && path != h.tail.path {
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
	if id := jstr(params, "agent_id"); id != "" do jw_str(&ev.w, "agent_id", id)
	if t := jstr(params, "agent_type"); t != "" do jw_str(&ev.w, "agent_type", t)
	if s := jstr(params, "source"); s != "" do jw_str(&ev.w, "source", s)
	if n := jstr(params, "notification_type"); n != "" do jw_str(&ev.w, "notification_type", n)
	if m := jstr(params, "message"); m != "" && name == "Notification" do jw_str(&ev.w, "message", m)
	event_send(ev)

	update_dialogs(name, tool, params)
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
		status := name == "PermissionDenied" ? "denied" : tool == "AskUserQuestion" ? "answered" : "allowed"
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
		for t in h.pending_tools do pending_tool_free(t)
		clear(&h.pending_tools)
	}
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

@(private = "file")
open_dialog :: proc(cl: ^Client, req_id, id, kind, tool, input, suggestions: string) {
	h := hub()
	d := new(Dialog)
	d.id = strings.clone(id)
	d.kind = strings.clone(kind)
	d.tool = strings.clone(tool)
	d.input = strings.clone(input)
	d.suggestions = strings.clone(suggestions)
	d.created_at = wall_ms()
	d.hook_client = cl.id
	d.hook_req = strings.clone(req_id)
	append(&h.dialogs, d)
	ev := event("dialog.open")
	write_dialog(&ev.w, d)
	event_send(ev)
	set_state("awaiting_input")
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
	free(d)
	if len(h.dialogs) == 0 && h.state == "awaiting_input" do set_state("busy")
}

cancel_open_dialogs :: proc() {
	h := hub()
	for len(h.dialogs) > 0 {
		d := h.dialogs[0]
		close_dialog(d, d.kind == "question" || d.kind == "elicitation" ? "cancelled" : "denied", "", "")
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
		set_state("idle")
		for t in h.pending_tools do pending_tool_free(t)
		clear(&h.pending_tools)
	}
}

// ---------- Transcript ----------

hub_poll_transcript :: proc() {
	h := hub()
	if h.tail.path == "" do return
	fd := c_open(strings.clone_to_cstring(h.tail.path, context.temp_allocator), 0)
	if fd < 0 do return // Claude Code creates it with the first message.
	defer c_close(fd)
	chunk := make([dynamic]u8, context.temp_allocator)
	buf: [65536]u8
	if c_lseek(fd, h.tail.offset, 0) < 0 do return
	for {
		n := c_read(fd, &buf[0], len(buf))
		if n <= 0 do break
		append(&chunk, ..buf[:n])
	}
	if len(chunk) == 0 do return
	line_offset := h.tail.offset - i64(len(h.tail.partial))
	h.tail.offset += i64(len(chunk))
	data := make([dynamic]u8, context.temp_allocator)
	append(&data, ..h.tail.partial[:])
	append(&data, ..chunk[:])
	clear(&h.tail.partial)
	start := 0
	for i in 0 ..< len(data) {
		if data[i] != '\n' do continue
		historic := line_offset + i64(i) < h.tail.catchup_end
		handle_transcript_line(string(data[start:i]), historic)
		start = i + 1
	}
	append(&h.tail.partial, ..data[start:])
}

@(private = "file")
handle_transcript_line :: proc(line: string, historic: bool) {
	h := hub()
	if enabled, ok := parse_repl_mode(line); ok {
		set_meta_bool("code_mode", &h.code_mode, enabled)
		return
	}
	entry, ok := parse_line(line)
	if !ok do return
	publish_entry(&entry, historic)
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
			event_send(ev)
		}
	}
	prompt_id := ""
	if !historic {
		if entry.origin == "notification" || entry.origin == "terminal" {
			for p, i in h.in_flight {
				if prompt_matches(p.text, entry.text) {
					prompt_id = strings.clone(p.id, context.temp_allocator)
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
			set_state("idle")
		case "terminal", "external", "notification":
			if !entry.sidechain do set_state("busy")
		}
	}
	emit_entry(entry, prompt_id, historic, nil)
}

emit_entry :: proc(entry: ^Entry, prompt_id: string, historic: bool, only: ^Client) {
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
	jw_bool(&ev.w, "sidechain", entry.sidechain)
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
	seen_norm := normalize_prompt(seen)
	if normalize_prompt(sent) == seen_norm do return true
	t := truncate(sent)
	return t != sent && normalize_prompt(t) == seen_norm
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
hub_send_prompt :: proc(text, transport: string, command := false) -> (^Prompt, string) {
	h := hub()
	if strings.trim_space(text) == "" do return nil, "prompt is empty"
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
	return h.session_started && len(h.dialogs) == 0 && h.state != "awaiting_input" && h.mode_task == nil && !app.child_exited
}

flush_inproc_queue :: proc() {
	h := hub()
	for len(h.inproc_queue) > 0 && can_type_prompt() {
		p := h.inproc_queue[0]
		ordered_remove(&h.inproc_queue, 0)
		append(&h.in_flight, p)
		feed_prompt(p.text)
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
feed_prompt :: proc(text: string) {
	h := hub()
	paste := fmt.tprintf("\x1b[200~%s\x1b[201~", text)
	h.prompt_submitted = false
	h.feed_gen += 1
	// A retried Enter is only safe where it can't do anything else. During a turn the
	// prompt is queued with no hook to confirm it, and a slash command may open a
	// menu where Enter would pick an option.
	retry := h.state == "idle" && !strings.has_prefix(strings.trim_left_space(text), "/")
	route := input_route()
	send_input(route, transmute([]u8)paste)
	// Enter must arrive separately, or the TUI treats it as part of the paste.
	timer_add(KEY_DELAY_MS, .Input, "\r", route)
	if retry do timer_add(KEY_DELAY_MS + ENTER_RETRY_MS, .Enter_Retry, "", route, 1, h.feed_gen)
}

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
		if reason := jstr(e, "stop_reason"); reason != "" {
			ev := event("stream.stop_reason")
			jw_int(&ev.w, "stream", i64(n))
			jw_str(&ev.w, "stop_reason", reason)
			event_send(ev)
		}
	case "message_stop":
		end_stream(s, "done")
	case "stream_end":
		if !jbool(e, "stopped") do end_stream(s, "aborted")
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
	case .Enter_Retry:
		// UserPromptSubmit comes before anything that could open a dialog, so once it
		// is seen no further Enter is sent that could answer one.
		if h.prompt_submitted || t.gen != h.feed_gen || len(h.dialogs) > 0 do return
		send_input(t.route, transmute([]u8)string("\r"))
		if t.n < ENTER_RETRIES do timer_add(ENTER_RETRY_MS, .Enter_Retry, "", t.route, t.n + 1, t.gen)
	case .Mode_Step:
		mode_step()
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
	if h.screen_dirty && now_ms() - h.screen_checked_at >= 250 {
		h.screen_dirty = false
		h.screen_checked_at = now_ms()
		if mode, ok := detect_mode(app.screen); ok && len(h.dialogs) == 0 {
			set_meta("permission_mode", &h.permission_mode, mode)
		}
	}
}

hub_stdio_closed :: proc() {
	// The consumer that owns a headless session has gone, so end it.
	if app.child_pid > 0 && !app.child_exited do c_kill(app.child_pid, SIGHUP)
}

hub_on_child_exit :: proc(code: int) {
	h := hub()
	app.child_exited = true
	app.exit_code = code
	h.exited_code = code
	hub_poll_transcript()
	cancel_open_dialogs()
	set_state("exited")
}

hub_on_exit :: proc() {
	ev := event("exit")
	jw_int(&ev.w, "code", i64(app.exit_code))
	event_send(ev)
}

// The permission mode as the footer shows it, e.g. "⏵⏵ accept edits on (shift+tab to
// cycle)". Only trusted while the footer is visible.
detect_mode :: proc(s: ^Screen) -> (string, bool) {
	lines := screen_lines(s)
	from := max(len(lines) - 8, 0)
	saw_footer := false
	for i := len(lines) - 1; i >= from; i -= 1 {
		line := strings.to_lower(lines[i], context.temp_allocator)
		compact, _ := strings.remove_all(line, " ", context.temp_allocator)
		if strings.contains(compact, "shift+tab") || strings.contains(compact, "?forshortcuts") {
			saw_footer = true
		} else {
			continue
		}
		switch {
		case strings.contains(compact, "acceptedits"): return "acceptEdits", true
		case strings.contains(compact, "planmode"): return "plan", true
		case strings.contains(compact, "bypasspermissions"): return "bypassPermissions", true
		case strings.contains(compact, "automode"): return "auto", true
		case strings.contains(compact, "dontask"): return "dontAsk", true
		}
	}
	if saw_footer do return "default", true
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
