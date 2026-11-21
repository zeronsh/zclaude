package zclaude

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ---------- Helpers ----------

Capture :: struct {
	rd: c.int,
	cl: ^Client,
	buf: [dynamic]u8,
}

reset_app :: proc() {
	app = {}
	app.pty_fd = -1
	app.listen_fd = -1
	app.screen = screen_make(80, 24)
	hub_init()
}

capture :: proc(subscribed := true) -> ^Capture {
	fds: [2]c.int
	c_pipe(&fds)
	set_nonblocking(fds[0])
	set_nonblocking(fds[1])
	cap := new(Capture)
	cap.rd = fds[0]
	cap.cl = client_add(-1, fds[1])
	cap.cl.subscribed = subscribed
	return cap
}

// Messages written to the captured client since the last drain.
drain :: proc(cap: ^Capture) -> []Value {
	buf: [65536]u8
	for {
		n := c_read(cap.rd, &buf[0], len(buf))
		if n <= 0 do break
		append(&cap.buf, ..buf[:n])
	}
	out := make([dynamic]Value, context.temp_allocator)
	start := 0
	for i in 0 ..< len(cap.buf) {
		if cap.buf[i] != '\n' do continue
		if v, ok := parse_json(string(cap.buf[start:i])); ok do append(&out, v)
		start = i + 1
	}
	remove_range(&cap.buf, 0, start)
	return out[:]
}

events_of :: proc(msgs: []Value, method: string) -> []Value {
	out := make([dynamic]Value, context.temp_allocator)
	for m in msgs do if jstr(m, "method") == method do append(&out, jget(m, "params"))
	return out[:]
}

hook_event :: proc(s: string) {
	v, ok := parse_json(s)
	assert(ok, s)
	hub_on_hook_event(v)
}

stream_event :: proc(s: string) {
	v, ok := parse_json(s)
	assert(ok, s)
	hub_on_stream_event(v)
}

temp_transcript :: proc(name: string, contents := "") -> string {
	path := fmt.tprintf("/tmp/zclaude-test-%d-%s.jsonl", c_getpid(), name)
	_ = os.write_entire_file(path, transmute([]u8)contents)
	return path
}

append_file :: proc(path, text: string) {
	fd := c_open(strings.clone_to_cstring(path, context.temp_allocator), O_WRONLY | 0x8 when ODIN_OS == .Darwin else O_WRONLY | 0o2000)
	write_all(fd, transmute([]u8)text)
	c_close(fd)
}

user_line :: proc(uuid, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":"user","uuid":"`)
	strings.write_string(&b, uuid)
	strings.write_string(&b, `","sessionId":"s","message":{"content":`)
	write_quoted(&b, text)
	strings.write_string(&b, "}}\n")
	return strings.to_string(b)
}

// ---------- Transcript ----------

@(test)
keeps_typed_prompt :: proc(t: ^testing.T) {
	e, ok := parse_line(`{"type":"user","uuid":"u","sessionId":"s","timestamp":"t","message":{"role":"user","content":"hello"}}`)
	testing.expect(t, ok)
	testing.expect_value(t, e.origin, "terminal")
	testing.expect_value(t, e.text, "hello")
	testing.expect_value(t, e.role, "user")
}

@(test)
extracts_rewake_prompts :: proc(t: ^testing.T) {
	content := fmt.tprintf("<task-notification>\n<summary>x</summary>\n</task-notification>\n<system-reminder>\n%s do it\nnow\n</system-reminder>", REWAKE_PREFIX)
	e, _ := parse_line(user_line("u", content))
	testing.expect_value(t, e.origin, "notification")
	testing.expect_value(t, e.text, "do it\nnow")
	d, _ := parse_line(user_line("u", "<task-notification>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command \"Stop\": hi there\n</system-reminder>"))
	testing.expect_value(t, d.text, "hi there")
}

@(test)
hides_private_lines_and_signature_only_thinking :: proc(t: ^testing.T) {
	for kind in ([]string{"attachment", "api-request-blob", "session-owner", "last-prompt"}) {
		_, ok := parse_line(fmt.tprintf(`{{"type":"%s","uuid":"u","message":{{"content":"secret"}}}}`, kind))
		testing.expect(t, !ok, kind)
	}
	_, ok := parse_line(`{"type":"assistant","uuid":"u","message":{"content":[{"type":"thinking","thinking":"","signature":"abc"}]}}`)
	testing.expect(t, !ok)
}

@(test)
publishes_prompts_absorbed_mid_turn_only :: proc(t: ^testing.T) {
	wake := fmt.tprintf("<task-notification>\n</task-notification>\n<system-reminder>\n%s mango\n</system-reminder>", REWAKE_PREFIX)
	b := strings.builder_make(context.temp_allocator)
	write_quoted(&b, wake)
	e, ok := parse_line(fmt.tprintf(`{{"type":"attachment","uuid":"a","attachment":{{"type":"queued_command","commandMode":"task-notification","prompt":%s}}}}`, strings.to_string(b)))
	testing.expect(t, ok)
	testing.expect_value(t, e.origin, "notification")
	testing.expect_value(t, e.text, "mango")
	typed, _ := parse_line(`{"type":"attachment","uuid":"a","attachment":{"type":"queued_command","commandMode":"prompt","prompt":"typed"}}`)
	testing.expect_value(t, typed.origin, "terminal")
	_, private := parse_line(`{"type":"attachment","uuid":"a","attachment":{"type":"prompt_snapshot","prompt":"secret"}}`)
	testing.expect(t, !private)
}

@(test)
slims_images_signatures_and_long_strings :: proc(t: ^testing.T) {
	long := strings.repeat("é", MAX_STRING, context.temp_allocator)
	line := fmt.tprintf(`{{"type":"user","uuid":"u","message":{{"content":[{{"type":"tool_result","tool_use_id":"t","content":[{{"type":"text","text":"%s"}},{{"type":"image","source":{{"data":"AAAA"}}}}]}}]}}}}`, long)
	e, ok := parse_line(line)
	testing.expect(t, ok)
	testing.expect_value(t, e.origin, "tool_result")
	testing.expect(t, !strings.contains(e.blocks, "AAAA"))
	testing.expect(t, strings.contains(e.blocks, "truncated"))
	testing.expect(t, len(e.blocks) < MAX_STRING + 512)
}

@(test)
ignores_bad_json_and_reads_repl_mode :: proc(t: ^testing.T) {
	_, ok := parse_line("{not json")
	testing.expect(t, !ok)
	on, ok1 := parse_repl_mode(`{"type":"repl-mode","replMode":true,"sessionId":"s"}`)
	testing.expect(t, ok1 && on)
	off, ok2 := parse_repl_mode(`{"type":"repl-mode","replMode":false}`)
	testing.expect(t, ok2 && !off)
	_, ok3 := parse_repl_mode(`{"type":"mode","mode":"normal"}`)
	testing.expect(t, !ok3)
}

@(test)
parses_model_switch_stdout :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"<local-command-stdout>Set model to `Haiku 5.5` and saved as your default for new sessions</local-command-stdout>", "Haiku 5.5"},
		{"<local-command-stdout>Set model to `Sonnet 5.5` for this session only</local-command-stdout>", "Sonnet 5.5"},
		{"<local-command-stdout>Kept model as `Opus 5.5`</local-command-stdout>", "Opus 5.5"},
		{"<local-command-stdout>\x1b[1mFast mode ON\x1b[0m · model set to `Opus 5.5`</local-command-stdout>", "Opus 5.5"},
		{"<local-command-stdout>Set model to claude-sonnet-4-5 for this session only</local-command-stdout>", "claude-sonnet-4-5"},
	}
	for tc in cases {
		model, ok := parse_model_switch_output(tc[0])
		testing.expect(t, ok, tc[0])
		testing.expect_value(t, model, tc[1])
	}
	_, ok := parse_model_switch_output("<local-command-stdout>Model not found: bogus</local-command-stdout>")
	testing.expect(t, !ok)
}

@(test)
unwraps_pasted_content :: proc(t: ^testing.T) {
	e, _ := parse_line(user_line("u", "\n\n<pasted_content id=\"d093\">\n Try it\n\nline two\n</pasted_content id=\"d093\">\n"))
	testing.expect_value(t, e.origin, "terminal")
	testing.expect_value(t, e.text, "Try it\n\nline two")
	mixed := "before\n\n<pasted_content id=\"0a1f\">\nhello\n<\\pasted_content id=\"0000\">\n<\\/pasted_content id=\"0000\">\n</pasted_content id=\"0a1f\">\n\nafter"
	testing.expect_value(t, unwrap_pasted_content(mixed), "before\n\nhello\n<pasted_content id=\"0000\">\n</pasted_content id=\"0000\">\n\nafter")
	literal := "keep <pasted_content id=\"zzzz\">\nnot hex\n</pasted_content id=\"zzzz\"> as-is"
	testing.expect_value(t, unwrap_pasted_content(literal), literal)
}

@(test)
parses_command_invocation :: proc(t: ^testing.T) {
	a, _ := parse_command_invocation("<command-name>/compact</command-name>\n<command-args></command-args>")
	testing.expect_value(t, a, "/compact")
	b, _ := parse_command_invocation("<command-name>/model</command-name>\n<command-args>haiku</command-args>")
	testing.expect_value(t, b, "/model haiku")
	_, ok := parse_command_invocation("<local-command-stdout>ok</local-command-stdout>")
	testing.expect(t, !ok)
}

// ---------- Settings ----------

@(test)
settings_quote_paths_and_hold_permission_hooks :: proc(t: ^testing.T) {
	s, err := build_settings("/a b/it's", "/s.sock", "")
	testing.expect_value(t, err, "")
	v, _ := parse_json(s)
	cmd := jstr(jarr(jarr(v, "hooks", "PreToolUse")[0], "hooks")[0], "command")
	testing.expect_value(t, cmd, `'/a b/it'\''s' __hook event '/s.sock'`)
	stop := jarr(v, "hooks", "Stop")
	testing.expect_value(t, len(stop), 2)
	testing.expect(t, jbool(jarr(stop[1], "hooks")[0], "asyncRewake"))
	perm := jarr(jarr(v, "hooks", "PermissionRequest")[0], "hooks")[0]
	testing.expect_value(t, jstr(perm, "command"), `'/a b/it'\''s' __hook permission '/s.sock'`)
	timeout, _ := jint(perm, "timeout")
	testing.expect(t, timeout * 1000 < i64(max(i32)), "held hooks stay under Node's timer limit")
	testing.expect(t, jhas(v, "hooks", "Elicitation"))
	testing.expect(t, jbool(v, "showThinkingSummaries"))
	testing.expect(t, jbool(v, "skipAutoPermissionPrompt"))
}

@(test)
settings_keep_user_values_and_hooks :: proc(t: ^testing.T) {
	user := `{"model":"x","showThinkingSummaries":false,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}`
	s, _ := build_settings("z", "s", user)
	v, _ := parse_json(s)
	testing.expect_value(t, jstr(v, "model"), "x")
	testing.expect(t, !jbool(v, "showThinkingSummaries"))
	stop := jarr(v, "hooks", "Stop")
	testing.expect_value(t, jstr(jarr(stop[0], "hooks")[0], "command"), "mine")
	testing.expect_value(t, len(stop), 3)
	_, bad := build_settings("z", "s", "[1]")
	testing.expect(t, bad != "")
}

// ---------- Answers ----------

color_question :: `{"questions":[{"question":"Color?","options":[{"label":"Red"},{"label":"Green"}],"multiSelect":false}]}`

@(test)
answers_map_labels_and_free_text :: proc(t: ^testing.T) {
	input, _ := parse_json(color_question)
	a1, _ := parse_json(`[{"selected":["Green"]}]`)
	out, err := build_answers(input, a1)
	testing.expect_value(t, err, "")
	testing.expect_value(t, string(out["Color?"].(json.String)), "Green")
	a2, _ := parse_json("[{\"other\":\"bl\\u001b[Aue\\nish\"}]")
	out2, _ := build_answers(input, a2)
	testing.expect_value(t, string(out2["Color?"].(json.String)), "bl[Aue ish")
	multi, _ := parse_json(`{"questions":[{"question":"T","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]}`)
	a3, _ := parse_json(`[{"selected":["A","B"],"other":"own"}]`)
	out3, _ := build_answers(multi, a3)
	testing.expect_value(t, string(out3["T"].(json.String)), "A, B, own")
	a4, _ := parse_json(`{"Color?":"Purple"}`)
	out4, _ := build_answers(input, a4)
	testing.expect_value(t, string(out4["Color?"].(json.String)), "Purple")
}

@(test)
bad_answers_are_refused :: proc(t: ^testing.T) {
	input, _ := parse_json(color_question)
	for bad in ([]string{`[{"selected":["Blue"]}]`, `[{"selected":["Red","Green"]}]`, `[{"selected":["Red"],"other":"x"}]`, `[{}]`, `[]`, `{"Other?":"x"}`, `5`}) {
		a, _ := parse_json(bad)
		_, err := build_answers(input, a)
		testing.expect(t, err != "", bad)
	}
}

// ---------- Screen ----------

@(test)
screen_draws_moves_and_erases :: proc(t: ^testing.T) {
	s := screen_make(10, 4)
	defer screen_destroy(s)
	screen_feed(s, transmute([]u8)string("hello\r\nworld"))
	lines := screen_lines(s)
	testing.expect_value(t, lines[0], "hello")
	testing.expect_value(t, lines[1], "world")
	screen_feed(s, transmute([]u8)string("\x1b[1;3H\x1b[K"))
	testing.expect_value(t, screen_lines(s)[0], "he")
	screen_feed(s, transmute([]u8)string("\x1b[2J\x1b[H0123456789ab"))
	lines = screen_lines(s)
	testing.expect_value(t, lines[0], "0123456789")
	testing.expect_value(t, lines[1], "ab")
	// Scrolling off the bottom.
	screen_feed(s, transmute([]u8)string("\x1b[4;1Hlast\nnext"))
	lines = screen_lines(s)
	testing.expect_value(t, lines[2], "last")
	testing.expect_value(t, lines[3], "    next")
}

@(test)
screen_handles_wide_chars_alt_screen_and_redraw :: proc(t: ^testing.T) {
	s := screen_make(20, 3)
	defer screen_destroy(s)
	screen_feed(s, transmute([]u8)string("\x1b[1;31m日本\x1b[0m ⏺ ok\x1b]0;title\x07"))
	testing.expect_value(t, screen_lines(s)[0], "日本 ⏺ ok")
	testing.expect_value(t, s.cx, 9)
	copy_ := screen_make(20, 3)
	defer screen_destroy(copy_)
	screen_feed(copy_, transmute([]u8)screen_render(s))
	testing.expect_value(t, screen_lines(copy_)[0], "日本 ⏺ ok")
	testing.expect_value(t, copy_.main[0].attr.fg, u32(1 << 24 | 1))
	testing.expect_value(t, copy_.cx, s.cx)
	screen_feed(s, transmute([]u8)string("\x1b[?1049h\x1b[Hmenu"))
	testing.expect_value(t, screen_lines(s)[0], "menu")
	screen_feed(s, transmute([]u8)string("\x1b[?1049l"))
	testing.expect_value(t, screen_lines(s)[0], "日本 ⏺ ok")
	// A UTF-8 character split across two reads.
	screen_feed(s, []u8{'\r', '\n', 0xe2, 0x8f})
	screen_feed(s, []u8{0xba})
	testing.expect_value(t, screen_lines(s)[1], "⏺")
}

@(test)
detects_permission_mode_from_footer :: proc(t: ^testing.T) {
	s := screen_make(60, 6)
	defer screen_destroy(s)
	screen_feed(s, transmute([]u8)string("\x1b[6;1H  ⏵⏵ accept edits on (shift+tab to cycle)"))
	mode, ok := detect_mode(s)
	testing.expect(t, ok)
	testing.expect_value(t, mode, "acceptEdits")
	screen_feed(s, transmute([]u8)string("\x1b[6;1H\x1b[2K  ⏸ plan mode on (shift+tab to cycle)"))
	mode, _ = detect_mode(s)
	testing.expect_value(t, mode, "plan")
	screen_feed(s, transmute([]u8)string("\x1b[6;1H\x1b[2K  ? for shortcuts"))
	mode, _ = detect_mode(s)
	testing.expect_value(t, mode, "default")
	screen_feed(s, transmute([]u8)string("\x1b[2J"))
	_, ok = detect_mode(s)
	testing.expect(t, !ok, "no footer, no guess")
}

@(test)
json_strings_are_escaped_and_repaired :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	write_quoted(&b, "a\"b\\c\n\x01é ")
	testing.expect_value(t, strings.to_string(b), "\"a\\\"b\\\\c\\n\\u0001é\\u2028\"")
	strings.builder_reset(&b)
	bad := []u8{'x', 0xff, 'y'}
	write_quoted(&b, string(bad))
	testing.expect_value(t, strings.to_string(b), "\"x�y\"")
	testing.expect_value(t, utf8_complete_len([]u8{'a', 0xe2, 0x8f}), 1)
	testing.expect_value(t, utf8_complete_len([]u8{'a', 0xe2, 0x8f, 0xba}), 4)
}

@(test)
names_keys :: proc(t: ^testing.T) {
	reset_app()
	for tc in ([][2]string{{"enter", "\r"}, {"esc", "\x1b"}, {"shift+tab", "\x1b[Z"}, {"ctrl+c", "\x03"}, {"alt+b", "\x1bb"}, {"down", "\x1b[B"}}) {
		got, ok := key_bytes(tc[0])
		testing.expect(t, ok, tc[0])
		testing.expect_value(t, got, tc[1])
	}
	_, ok := key_bytes("hyper+x")
	testing.expect(t, !ok)
}

// ---------- Session ----------

@(test)
permission_dialog_links_to_its_call_and_answers_through_the_held_hook :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	hook := capture(subscribed = false)
	hook_event(`{"hook_event_name":"SessionStart"}`)
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"touch a","description":"x"}}`)
	testing.expect_value(t, hub().state, "busy")
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"description":"x","command":"touch a"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch:*"}],"behavior":"allow","destination":"localSettings"}]}`)
	hub_on_permission_request(hook.cl, "7", req)
	testing.expect_value(t, hub().state, "awaiting_input")
	opened := events_of(drain(cap), "dialog.open")
	testing.expect_value(t, len(opened), 1)
	testing.expect_value(t, jstr(opened[0], "id"), "b1")
	testing.expect_value(t, jstr(opened[0], "kind"), "permission")
	testing.expect(t, jbool(opened[0], "held"))

	bad, _ := parse_json(`{"id":"b1","decision":"maybe"}`)
	_, err := rpc_dialog_respond(bad)
	testing.expect(t, err != "")
	ok_params, _ := parse_json(`{"id":"b1","decision":"allow_always"}`)
	res, err2 := rpc_dialog_respond(ok_params)
	testing.expect_value(t, err2, "")
	testing.expect(t, strings.contains(res, `"allowed"`))
	replies := drain(hook)
	testing.expect_value(t, len(replies), 1)
	id, _ := jint(replies[0], "id")
	testing.expect_value(t, id, 7)
	output, _ := parse_json(jstr(replies[0], "result", "output"))
	testing.expect_value(t, jstr(output, "hookSpecificOutput", "decision", "behavior"), "allow")
	testing.expect_value(t, jstr(jarr(output, "hookSpecificOutput", "decision", "updatedPermissions")[0], "type"), "addRules")
	updates := events_of(drain(cap), "dialog.update")
	testing.expect_value(t, jstr(updates[0], "status"), "allowed")
	testing.expect_value(t, jstr(updates[0], "resolved_by"), "rpc")
	testing.expect_value(t, hub().state, "busy")
}

@(test)
questions_answer_with_updated_input_and_prompts_wait_for_dialogs :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	hook := capture(subscribed = false)
	hook_event(`{"hook_event_name":"SessionStart"}`)
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":` + color_question + `}`)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":` + color_question + `}`)
	hub_on_permission_request(hook.cl, "1", req)
	// A prompt sent now would be typed into the dialog, so it waits.
	p, err := hub_send_prompt("next", "inproc")
	testing.expect_value(t, err, "")
	testing.expect_value(t, p.status, "queued")
	answer, _ := parse_json(`{"id":"q1","answers":[{"selected":["Green"]}]}`)
	_, err2 := rpc_dialog_respond(answer)
	testing.expect_value(t, err2, "")
	output, _ := parse_json(jstr(drain(hook)[0], "result", "output"))
	testing.expect_value(t, jstr(output, "hookSpecificOutput", "decision", "updatedInput", "answers", "Color?"), "Green")
	testing.expect_value(t, len(jarr(output, "hookSpecificOutput", "decision", "updatedInput", "questions")), 1)
	// The card is still on screen until Claude Code takes it down, so typing waits
	// for the tool to report back.
	flush_inproc_queue()
	testing.expect_value(t, p.status, "queued")
	hook_event(`{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{}}`)
	flush_inproc_queue()
	testing.expect_value(t, p.status, "delivered")
	msgs := drain(cap)
	testing.expect_value(t, jstr(events_of(msgs, "dialog.update")[0], "answers", "Color?"), "Green")
}

@(test)
typing_waits_out_a_card_that_never_reports_back :: proc(t: ^testing.T) {
	reset_app()
	hook := capture(subscribed = false)
	hook_event(`{"hook_event_name":"SessionStart"}`)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}`)
	hub_on_permission_request(hook.cl, "1", req)
	p, _ := hub_send_prompt("next", "inproc")
	allow, _ := parse_json(`{"id":"perm-1","decision":"allow"}`)
	_, err := rpc_dialog_respond(allow)
	testing.expect_value(t, err, "")
	flush_inproc_queue()
	testing.expect_value(t, p.status, "queued")
	st := hub().settle.?
	hub().settle = Settle{id = st.id, tool = st.tool, kind = st.kind, until = now_ms() - 1}
	flush_inproc_queue()
	testing.expect_value(t, p.status, "delivered")
	// The same holds for an Enter: a card that opens after the paste keeps it back.
	hook2 := capture(subscribed = false)
	hub_on_permission_request(hook2.cl, "2", req)
	enter_timers := 0
	for tm in app.timers do if tm.kind == .Enter do enter_timers += 1
	testing.expect_value(t, enter_timers, 1)
	for tm in app.timers do if tm.kind == .Enter do hub_on_timer(tm)
	held := 0
	for tm in app.timers do if tm.kind == .Enter && tm.n == 1 do held += 1
	testing.expect_value(t, held, 1)
}

@(test)
the_terminal_can_answer_first :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	hook := capture(subscribed = false)
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":` + color_question + `}`)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":` + color_question + `}`)
	hub_on_permission_request(hook.cl, "1", req)
	// Claude Code stops the hook once the TUI has the answer.
	client_close(hook.cl)
	held := events_of(drain(cap), "dialog.update")
	testing.expect(t, !jbool(held[0], "held"))
	answer, _ := parse_json(`{"id":"q1","answers":[{"selected":["Red"]}]}`)
	_, err := rpc_dialog_respond(answer)
	testing.expect(t, strings.contains(err, "terminal"))
	hook_event(`{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{"answers":{"Color?":"Green"}}}`)
	closed := events_of(drain(cap), "dialog.update")
	testing.expect_value(t, jstr(closed[0], "status"), "answered")
	testing.expect_value(t, jstr(closed[0], "resolved_by"), "terminal")
	testing.expect_value(t, jstr(closed[0], "answers", "Color?"), "Green")
}

@(test)
plan_approval_sets_the_mode_and_interrupt_refuses_held_dialogs :: proc(t: ^testing.T) {
	reset_app()
	hook := capture(subscribed = false)
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_use_id":"p1","tool_input":{"plan":"x"}}`)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}`)
	hub_on_permission_request(hook.cl, "1", req)
	testing.expect_value(t, hub().dialogs[0].kind, "plan")
	// bypassPermissions only when the card offers it.
	bypass, _ := parse_json(`{"id":"p1","decision":"approve","mode":"bypassPermissions"}`)
	_, berr := rpc_dialog_respond(bypass)
	testing.expect(t, berr != "")
	approve, _ := parse_json(`{"id":"p1","decision":"approve","mode":"acceptEdits","plan":"y","message":"also add tests"}`)
	res, err := rpc_dialog_respond(approve)
	testing.expect_value(t, err, "")
	output, _ := parse_json(jstr(drain(hook)[0], "result", "output"))
	perm := jarr(output, "hookSpecificOutput", "decision", "updatedPermissions")[0]
	testing.expect_value(t, jstr(perm, "type"), "setMode")
	testing.expect_value(t, jstr(perm, "mode"), "acceptEdits")
	// ExitPlanMode needs a person, so Claude Code only takes an allow that carries the
	// input. An edited plan goes back the same way.
	testing.expect_value(t, jstr(output, "hookSpecificOutput", "decision", "updatedInput", "plan"), "y")
	// Feedback follows as a prompt, once the card has gone.
	reply, _ := parse_json(res)
	testing.expect_value(t, jstr(reply, "mode"), "acceptEdits")
	testing.expect(t, jstr(reply, "prompt_id") != "")
	testing.expect_value(t, hub().inproc_queue[0].text, "also add tests")

	hook2 := capture(subscribed = false)
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"b2","tool_input":{"command":"rm x"}}`)
	req2, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm x"}}`)
	hub_on_permission_request(hook2.cl, "2", req2)
	ires := rpc_interrupt()
	testing.expect(t, strings.contains(ires, `"dialog"`))
	out2, _ := parse_json(jstr(drain(hook2)[0], "result", "output"))
	testing.expect_value(t, jstr(out2, "hookSpecificOutput", "decision", "behavior"), "deny")
	testing.expect(t, jbool(out2, "hookSpecificOutput", "decision", "interrupt"))
	testing.expect_value(t, len(hub().dialogs), 0)
}

@(test)
plan_modes_come_from_the_card_on_screen :: proc(t: ^testing.T) {
	reset_app()
	screen_feed(app.screen, transmute([]u8)string("Plan\r\n 1. Write the file\r\n 2. Check it\r\nWould you like to proceed?\r\n \u276f 1. Yes, and use auto mode\r\n   2. Yes, manually approve edits\r\n   3. Tell Claude what to change\r\n      shift+tab to approve with this feedback\r\n"))
	modes := plan_modes_on_screen(app.screen)
	testing.expect_value(t, len(modes), 2)
	testing.expect_value(t, modes[0], "auto")
	testing.expect_value(t, modes[1], "default")

	hook := capture(subscribed = false)
	cap := capture()
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_use_id":"p1","tool_input":{"plan":"x"}}`)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}`)
	hub_on_permission_request(hook.cl, "1", req)
	hub().screen_dirty = true
	hub_after_tick()
	update := events_of(drain(cap), "dialog.update")
	testing.expect_value(t, len(update), 1)
	testing.expect_value(t, len(jarr(update[0], "modes")), 2)
	// Approving without a mode takes the card's first choice, as Enter would.
	approve, _ := parse_json(`{"id":"p1","decision":"approve"}`)
	res, err := rpc_dialog_respond(approve)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(res, `"mode":"auto"`))
	output, _ := parse_json(jstr(drain(hook)[0], "result", "output"))
	testing.expect_value(t, jstr(jarr(output, "hookSpecificOutput", "decision", "updatedPermissions")[0], "mode"), "auto")
}

@(test)
nothing_is_typed_over_a_card_on_screen :: proc(t: ^testing.T) {
	reset_app()
	app.child_pid = 999_999_999
	hook_event(`{"hook_event_name":"SessionStart"}`)
	// A draft in the prompt box that looks like a list is not a card: the footer shows.
	screen_feed(app.screen, transmute([]u8)string("\x1b[20;1H\u276f 1. first\r\n  2. second\x1b[24;1H  ? for shortcuts"))
	testing.expect(t, !card_on_screen(app.screen))
	// A card with no hook behind it, as Claude Code draws one.
	screen_feed(app.screen, transmute([]u8)string("\x1b[2J\x1b[HWould you like to proceed?\r\n \u276f 1. Yes, and use auto mode\r\n   2. Yes, manually approve edits\r\n   3. Tell Claude what to change\r\n"))
	testing.expect(t, card_on_screen(app.screen))
	p, _ := hub_send_prompt("hello", "inproc")
	testing.expect_value(t, p.status, "queued")
	// Shutdown refuses it with Esc rather than typing /exit into it.
	begin_shutdown()
	testing.expect(t, app.shutdown.esc_at != 0)
	testing.expect_value(t, app.shutdown.exits, 0)
	screen_feed(app.screen, transmute([]u8)string("\x1b[2J\x1b[22;1H\u276f \x1b[24;1H  ? for shortcuts"))
	testing.expect(t, !card_on_screen(app.screen))
	shutdown_step()
	testing.expect_value(t, app.shutdown.exits, 1)
}

@(test)
a_card_without_a_hook_becomes_a_terminal_dialog :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	hook_event(`{"hook_event_name":"SessionStart"}`)
	screen_feed(app.screen, transmute([]u8)string("Earlier output\x1b[10;1H\u2594\u2594\u2594\u2594\u2594\u2594\u2594\u2594\u2594\u2594\u2594\u2594\r\n Select model\r\n \u276f 1. Default      Opus 5.5\r\n   2. Opus         Opus 5.5\r\n   3. Haiku        Haiku 5.5\r\n"))
	hub().screen_dirty = true
	hub_after_tick()
	// Not yet: a hook usually describes a card, and gets a moment to.
	testing.expect_value(t, len(hub().dialogs), 0)
	hub().card_since -= CARD_GRACE_MS
	hub().screen_dirty = true
	hub().screen_checked_at = 0
	hub_after_tick()
	opened := events_of(drain(cap), "dialog.open")
	testing.expect_value(t, len(opened), 1)
	testing.expect_value(t, jstr(opened[0], "kind"), "terminal")
	testing.expect_value(t, len(jarr(opened[0], "input", "options")), 3)
	testing.expect(t, strings.has_prefix(jstr(opened[0], "input", "text"), "Select model"))
	testing.expect_value(t, jstr(jarr(opened[0], "input", "options")[2]), "Haiku")
	testing.expect_value(t, hub().state, "awaiting_input")
	// Answered by number, as a person would pick it.
	bad, _ := parse_json(fmt.tprintf(`{{"id":"%s","option":9}}`, jstr(opened[0], "id")))
	_, berr := rpc_dialog_respond(bad)
	testing.expect(t, berr != "")
	pick, _ := parse_json(fmt.tprintf(`{{"id":"%s","option":3}}`, jstr(opened[0], "id")))
	res, err := rpc_dialog_respond(pick)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(res, `"answered"`))
	testing.expect_value(t, len(hub().dialogs), 0)
	testing.expect(t, settling())
	// The card leaving the screen ends the wait.
	screen_feed(app.screen, transmute([]u8)string("\x1b[2J\x1b[22;1H\u276f \x1b[24;1H  ? for shortcuts"))
	hub().screen_dirty = true
	hub().screen_checked_at = 0
	hub_after_tick()
	testing.expect(t, !settling())
}

@(test)
shutdown_ends_the_turn_then_types_exit_then_hangs_up :: proc(t: ^testing.T) {
	reset_app()
	app.child_pid = 999_999_999 // no such process: signals go nowhere
	hook_event(`{"hook_event_name":"SessionStart"}`)
	hook_event(`{"hook_event_name":"UserPromptSubmit"}`)
	testing.expect_value(t, begin_shutdown(), "graceful")
	testing.expect(t, app.shutdown.esc_at != 0)
	testing.expect_value(t, app.shutdown.exits, 0)
	app.shutdown.esc_at -= 1000
	hook_event(`{"hook_event_name":"Stop"}`)
	shutdown_step()
	testing.expect_value(t, app.shutdown.exits, 1)
	// Prompts are refused rather than typed into a closing session.
	_, err := hub_send_prompt("late", "inproc")
	testing.expect(t, strings.contains(err, "shutting down"))
	testing.expect_value(t, begin_shutdown(), "hangup")
	testing.expect_value(t, begin_shutdown(), "kill")
	hub_on_child_exit(137, 9)
	testing.expect_value(t, begin_shutdown(), "exited")
}

@(test)
a_turn_ending_cancels_open_dialogs_and_releases_hooks :: proc(t: ^testing.T) {
	reset_app()
	hook := capture(subscribed = false)
	hook_event(`{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":` + color_question + `}`)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":` + color_question + `}`)
	hub_on_permission_request(hook.cl, "1", req)
	hook_event(`{"hook_event_name":"Stop"}`)
	testing.expect_value(t, len(hub().dialogs), 0)
	testing.expect_value(t, hub().state, "idle")
	// The hook is told to leave the decision to the terminal.
	testing.expect_value(t, jstr(drain(hook)[0], "result", "output"), "")
}

@(test)
code_mode_inner_permissions_get_a_synthetic_id :: proc(t: ^testing.T) {
	reset_app()
	hook := capture(subscribed = false)
	req, _ := parse_json(`{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo inner"}}`)
	hub_on_permission_request(hook.cl, "1", req)
	testing.expect(t, strings.has_prefix(hub().dialogs[0].id, "perm-"))
	hook_event(`{"hook_event_name":"PostToolUse","tool_name":"Bash"}`)
	testing.expect_value(t, len(hub().dialogs), 0)
}

is_main :: proc(n: int) -> bool {
	s, ok := hub().streams[n]
	return ok && s.main
}

thread_call :: proc(n: int, previous := 0) {
	if previous == 0 {
		stream_event(fmt.tprintf(`{{"stream":%d,"type":"message_start","message_id":"m%d","in_thread":true,"shape":{{"tools":"main-tools","system":"main-system"}}}}`, n, n))
	} else {
		stream_event(fmt.tprintf(`{{"stream":%d,"type":"message_start","message_id":"m%d","in_thread":true,"previous_message_id":"m%d"}}`, n, n, previous))
	}
}

thread_root :: proc(n: int, tools, system: string) {
	stream_event(fmt.tprintf(`{{"stream":%d,"type":"message_start","message_id":"m%d","in_thread":true,"shape":{{"tools":"%s","system":"%s"}}}}`, n, n, tools, system))
}

record_in_transcript :: proc(path: string, n: int) {
	append_file(path, fmt.tprintf("{{\"type\":\"assistant\",\"uuid\":\"u%d\",\"message\":{{\"id\":\"m%d\",\"content\":[{{\"type\":\"text\",\"text\":\"x\"}}]}}}}\n", n, n))
	hub_poll_transcript()
}

@(test)
the_main_conversation_follows_its_chain :: proc(t: ^testing.T) {
	reset_app()
	thread_call(1)
	thread_call(2, 1)
	thread_call(3, 2)
	testing.expect(t, is_main(1) && is_main(2) && is_main(3))
	// Background calls aren't in a thread; subagents have their own chain.
	stream_event(`{"stream":4,"type":"message_start","message_id":"m4","in_thread":false,"shape":{"tools":"main-tools","system":"main-system"}}`)
	testing.expect(t, !is_main(4))
	thread_root(5, "agent-tools", "agent-system")
	thread_call(6, 5)
	testing.expect(t, !is_main(5) && !is_main(6))
	thread_call(7, 3)
	testing.expect(t, is_main(7))
	// Compaction changes the system prompt, an MCP server changes the tools.
	thread_root(8, "main-tools", "compacted-system")
	testing.expect(t, is_main(8))
	thread_root(9, "more-tools", "compacted-system")
	testing.expect(t, is_main(9))
	thread_root(10, "main-tools", "main-system")
	testing.expect(t, !is_main(10), "what it used to look like no longer counts")
}

@(test)
the_transcript_repairs_the_chain_and_teaches_new_shapes :: proc(t: ^testing.T) {
	reset_app()
	path := temp_transcript("shape")
	defer os.remove(path)
	hook_event(fmt.tprintf(`{{"hook_event_name":"SessionStart","transcript_path":"%s"}}`, path))
	thread_call(1)
	thread_root(2, "new-tools", "new-system")
	testing.expect(t, !is_main(2))
	record_in_transcript(path, 2)
	thread_root(3, "new-tools", "new-system")
	testing.expect(t, is_main(3), "recognized from then on")
	thread_call(4, 2)
	testing.expect(t, is_main(4))
}

@(test)
threadless_builds_stream_live_after_the_transcript_confirms :: proc(t: ^testing.T) {
	reset_app()
	path := temp_transcript("threadless")
	defer os.remove(path)
	hook_event(fmt.tprintf(`{{"hook_event_name":"SessionStart","transcript_path":"%s"}}`, path))
	stream_event(`{"stream":1,"type":"message_start","message_id":"m1","in_thread":false,"shape":{"tools":"main-tools","system":"main-system"},"cache_read_tokens":0,"cache_write_tokens":500}`)
	testing.expect(t, !is_main(1))
	record_in_transcript(path, 1)
	stream_event(`{"stream":2,"type":"message_start","message_id":"m2","in_thread":false,"shape":{"tools":"main-tools","system":"main-system"},"cache_read_tokens":500,"cache_write_tokens":200}`)
	stream_event(`{"stream":3,"type":"message_start","message_id":"m3","in_thread":false}`)
	stream_event(`{"stream":5,"type":"message_start","message_id":"m5","in_thread":false,"shape":{"tools":"main-tools","system":"main-system"},"cache_read_tokens":700,"cache_write_tokens":0}`)
	testing.expect(t, is_main(2), "later main turns stream live")
	testing.expect(t, !is_main(3), "a toolless title call stays hidden")
	testing.expect(t, !is_main(5), "a cache-read-only fork stays hidden")
}

@(test)
streams_forward_tokens_and_end_states :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	stream_event(`{"stream":1,"type":"message_start","message_id":"m1","model":"haiku","in_thread":true}`)
	stream_event(`{"stream":1,"type":"content_block_start","index":0,"block_type":"text"}`)
	stream_event(`{"stream":1,"type":"content_block_delta","index":0,"delta_type":"text_delta","text":"Hel"}`)
	stream_event(`{"stream":1,"type":"content_block_delta","index":0,"delta_type":"text_delta","text":"lo é"}`)
	// A subscriber arriving now gets the text so far in its snapshot.
	snap, _ := parse_json(snapshot_json())
	testing.expect_value(t, jstr(jarr(jarr(snap, "streams")[0], "blocks")[0], "text"), "Hello é")
	stream_event(`{"stream":1,"type":"message_stop"}`)
	stream_event(`{"stream":1,"type":"stream_end","stopped":true}`)
	stream_event(`{"stream":2,"type":"message_start","message_id":"m2"}`)
	stream_event(`{"stream":2,"type":"stream_end","stopped":false}`)
	msgs := drain(cap)
	deltas := events_of(msgs, "stream.delta")
	testing.expect_value(t, len(deltas), 2)
	ends := events_of(msgs, "stream.end")
	testing.expect_value(t, jstr(ends[0], "status"), "done")
	testing.expect_value(t, jstr(ends[1], "status"), "aborted")
	testing.expect_value(t, len(hub().streams), 0)
	// Sequence numbers increase by one per event.
	prev: i64 = 0
	for m in msgs {
		seq, _ := jint(m, "params", "seq")
		testing.expect(t, seq == prev + 1 || prev == 0)
		prev = seq
	}
}

@(test)
transcript_entries_resolve_prompts_and_interrupts :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	path := temp_transcript("prompts")
	defer os.remove(path)
	hook_event(fmt.tprintf(`{{"hook_event_name":"SessionStart","transcript_path":"%s","session_id":"s"}}`, path))
	sent := "Try it\n\nRan 1 shell command\n​hello"
	p, _ := hub_send_prompt(sent, "inproc")
	id := strings.clone(p.id, context.temp_allocator)
	append_file(path, user_line("u-pasted", "\n\n<pasted_content id=\"d093\">\n Try it\n\nRan 1 shell command\nhello\n</pasted_content id=\"d093\">\n"))
	hub_poll_transcript()
	msgs := drain(cap)
	entries := events_of(msgs, "entry")
	testing.expect_value(t, jstr(entries[0], "origin"), "external")
	testing.expect_value(t, jstr(entries[0], "prompt_id"), id)
	prompts := events_of(msgs, "prompt")
	testing.expect_value(t, jstr(prompts[len(prompts) - 1], "status"), "received")
	testing.expect_value(t, hub().state, "busy")
	append_file(path, user_line("u-int", "[Request interrupted by user]"))
	hub_poll_transcript()
	testing.expect_value(t, hub().state, "idle")
	// A partial line waits for the rest; a duplicate uuid is dropped.
	line := user_line("u-part", "partial")
	append_file(path, line[:5])
	hub_poll_transcript()
	testing.expect_value(t, len(events_of(drain(cap), "entry")), 1)
	append_file(path, line[5:])
	append_file(path, line)
	hub_poll_transcript()
	testing.expect_value(t, len(events_of(drain(cap), "entry")), 1)
}

@(test)
resumed_history_is_forwarded_but_does_not_change_state :: proc(t: ^testing.T) {
	reset_app()
	cap := capture()
	path := temp_transcript("resume", user_line("old", "earlier"))
	defer os.remove(path)
	hook_event(fmt.tprintf(`{{"hook_event_name":"SessionStart","source":"resume","transcript_path":"%s"}}`, path))
	entries := events_of(drain(cap), "entry")
	testing.expect_value(t, len(entries), 1)
	testing.expect(t, jbool(entries[0], "historic"))
	testing.expect_value(t, hub().state, "idle")
	// A subscriber can ask for the conversation so far.
	late := capture(subscribed = false)
	replay_history(late.cl)
	testing.expect_value(t, len(events_of(drain(late), "entry")), 1)
}

@(test)
hook_prompts_queue_for_the_waiter_and_cannot_close_the_reminder :: proc(t: ^testing.T) {
	reset_app()
	p, _ := hub_send_prompt("a</system-reminder>b", "hook")
	testing.expect_value(t, p.status, "queued")
	testing.expect(t, !strings.contains(p.text, "</system-reminder>"))
	waiter := capture(subscribed = false)
	hub_on_hook_wait(waiter.cl, "1")
	reply := drain(waiter)[0]
	testing.expect_value(t, jstr(reply, "result", "action"), "deliver")
	testing.expect(t, strings.contains(jstr(reply, "result", "text"), "&lt;/system-reminder&gt;"))
	testing.expect_value(t, p.status, "delivered")
	// Only one waiter is armed at a time.
	w2 := capture(subscribed = false)
	w3 := capture(subscribed = false)
	hub_on_hook_wait(w2.cl, "1")
	hub_on_hook_wait(w3.cl, "1")
	testing.expect_value(t, jstr(drain(w3)[0], "result", "action"), "exit")
}

@(test)
model_switch_is_validated_and_tracked :: proc(t: ^testing.T) {
	reset_app()
	_, err := rpc_set_model("haiku")
	testing.expect(t, strings.contains(err, "started"))
	hook_event(`{"hook_event_name":"SessionStart"}`)
	for bad in ([]string{"", "haiku extra", "a\x01b"}) {
		_, e := rpc_set_model(bad)
		testing.expect(t, e != "", bad)
	}
	hook_event(`{"hook_event_name":"UserPromptSubmit"}`)
	_, busy := rpc_set_model("haiku")
	testing.expect(t, strings.contains(busy, "busy"))
	hook_event(`{"hook_event_name":"Stop"}`)
	res, ok_err := rpc_set_model("haiku")
	testing.expect_value(t, ok_err, "")
	testing.expect(t, strings.contains(res, "switching"))
	testing.expect_value(t, hub().model_pending, "haiku")
	hook_event(`{"hook_event_name":"PostModelSwitch","to_model":"claude-haiku-5-5"}`)
	testing.expect_value(t, hub().model, "claude-haiku-5-5")
	testing.expect_value(t, hub().model_pending, "")
}

@(test)
interrupt_sends_esc_only_during_a_turn :: proc(t: ^testing.T) {
	reset_app()
	hook_event(`{"hook_event_name":"SessionStart"}`)
	testing.expect(t, strings.contains(rpc_interrupt(), `"sent":false`))
	hook_event(`{"hook_event_name":"UserPromptSubmit"}`)
	testing.expect(t, strings.contains(rpc_interrupt(), `"esc"`))
	testing.expect_value(t, hub().state, "idle")
}
