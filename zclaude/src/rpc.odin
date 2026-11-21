package zclaude

// JSON-RPC 2.0 over newline-delimited JSON, on stdio (`--stdio`) or the control
// socket. Requests carry `id`; events are notifications whose method names the
// event and whose params start with a sequence number.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

handle_message :: proc(cl: ^Client, line: string) {
	v, ok := parse_json(line)
	if !ok {
		reply_error(cl, "", "parse error", -32700)
		return
	}
	method := jstr(v, "method")
	id := ""
	if idv := jget(v, "id"); idv != nil do id = to_json(idv, context.temp_allocator)
	params := jget(v, "params")

	switch method {
	// ----- Internal: hooks and the in-process agent -----
	case "hook.event":
		cl.kind = .Hook_Event
		hub_on_hook_event(params)
		// The reply means the event was applied, which keeps hooks in order.
		reply_result(cl, id, "true")
	case "hook.pre_model_switch":
		cl.kind = .Hook_Event
		hub_on_hook_event(params)
		// Skips the "Switch model?" confirmation while respecting any user hook that blocks.
		reply_result(cl, id, `{"output":"{\"hookSpecificOutput\":{\"hookEventName\":\"PreModelSwitch\",\"permissionDecision\":\"allow\"}}"}`)
	case "hook.permission":
		cl.kind = .Hook_Permission
		hub_on_permission_request(cl, id, params)
	case "hook.elicitation":
		cl.kind = .Hook_Elicitation
		hub_on_elicitation(cl, id, params)
	case "hook.wait":
		hub_on_hook_wait(cl, id)
	case "agent.hello":
		hub_on_agent_hello(cl, params)
	case "agent.stream":
		hub_on_stream_event(params)
	case "agent.reply":
		hub_on_agent_reply(params)

	// ----- Public -----
	case "status":
		cl.kind = .Control
		reply_result(cl, id, snapshot_json())
	case "subscribe":
		cl.kind = .Control
		rpc_subscribe(cl, id, params)
	case "unsubscribe":
		cl.subscribed = false
		cl.sub_term = false
		reply_result(cl, id, "true")
	case "prompt.send":
		transport := jstr(params, "transport")
		if transport == "" do transport = "inproc"
		images, ierr := prompt_images(jarr(params, "images"))
		if ierr != "" {
			reply_error(cl, id, ierr)
			return
		}
		p, err := hub_send_prompt(jstr(params, "text"), transport, images = images)
		if err != "" {
			reply_error(cl, id, err)
			return
		}
		reply_result(cl, id, fmt.tprintf(`{{"prompt_id":"%s","status":"%s","transport":"%s"}}`, p.id, p.status, p.transport))
	case "command":
		text := strings.trim_space(jstr(params, "text"))
		if !strings.has_prefix(text, "/") {
			reply_error(cl, id, "a command starts with /, for example /compact")
			return
		}
		p, err := hub_send_prompt(text, "inproc")
		if err != "" {
			reply_error(cl, id, err)
			return
		}
		reply_result(cl, id, fmt.tprintf(`{{"prompt_id":"%s","status":"%s"}}`, p.id, p.status))
	case "interrupt":
		reply_result(cl, id, rpc_interrupt())
	case "dialog.respond":
		res, err := rpc_dialog_respond(params)
		if err != "" do reply_error(cl, id, err)
		else do reply_result(cl, id, res)
	case "model.set":
		res, err := rpc_set_model(jstr(params, "model"))
		if err != "" do reply_error(cl, id, err)
		else do reply_result(cl, id, res)
	case "task.stop":
		if err := hub_stop_task(cl, id, jstr(params, "id")); err != "" do reply_error(cl, id, err)
	case "effort.set":
		res, err := rpc_set_effort(jstr(params, "level"))
		if err != "" do reply_error(cl, id, err)
		else do reply_result(cl, id, res)
	case "mode.set":
		if err := hub_set_mode(cl, id, jstr(params, "mode")); err != "" do reply_error(cl, id, err)
	case "keys":
		if err := rpc_keys(params); err != "" do reply_error(cl, id, err)
		else do reply_result(cl, id, "true")
	case "term.write":
		data, err := param_bytes(params)
		if err != "" {
			reply_error(cl, id, err)
			return
		}
		pty_write(data)
		hub_on_terminal_input(data)
		reply_result(cl, id, "true")
	case "term.resize":
		if err := rpc_resize(params); err != "" do reply_error(cl, id, err)
		else do reply_result(cl, id, "true")
	case "screen":
		reply_result(cl, id, screen_json(jbool(params, "ansi")))
	case "memory":
		if err := hub_memory(cl, id); err != "" do reply_error(cl, id, err)
	case "shutdown":
		how := begin_shutdown(force = jbool(params, "force"))
		reply_result(cl, id, fmt.tprintf(`{{"stopping":"%s"}}`, how))
	case:
		if id != "" do reply_error(cl, id, fmt.tprintf("unknown method %q", method), -32601)
	}
}

@(private = "file")
rpc_subscribe :: proc(cl: ^Client, id: string, params: Value) {
	cl.subscribed = true
	cl.sub_term = jbool(params, "term")
	reply_result(cl, id, snapshot_json())
	if jbool(params, "history") do replay_history(cl)
	if cl.sub_term {
		// A terminal attaching now gets the current screen first.
		ev := event("term.output", term = true, only = cl)
		jw_str(&ev.w, "data", base64.encode(transmute([]u8)screen_render(app.screen), allocator = context.temp_allocator))
		jw_bool(&ev.w, "redraw", true)
		event_send(ev)
	}
}

@(private = "file")
param_bytes :: proc(params: Value) -> ([]byte, string) {
	if data := jstr(params, "data"); data != "" {
		bytes, err := base64.decode(data, allocator = context.temp_allocator)
		if err != nil do return nil, "data is not valid base64"
		return bytes, ""
	}
	if text := jstr(params, "text"); text != "" do return transmute([]u8)text, ""
	return nil, "pass `data` (base64) or `text`"
}

rpc_interrupt :: proc() -> string {
	h := hub()
	held := 0
	for d in h.dialogs do if d.hook_client != 0 do held += 1
	if held > 0 {
		// Refusing the dialog with `interrupt` stops the turn, like Esc on its card.
		output := `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user interrupted.","interrupt":true}}}`
		for len(h.dialogs) > 0 {
			d := h.dialogs[0]
			out := d.kind == "elicitation" ? `{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"cancel"}}` : output
			close_dialog(d, d.kind == "question" || d.kind == "elicitation" ? "cancelled" : "denied", "rpc", "", out)
		}
		return `{"sent":true,"via":"dialog"}`
	}
	if h.state != "busy" do return fmt.tprintf(`{{"sent":false,"state":"%s"}}`, h.state)
	// Esc cancels a turn. Only while a turn runs: at the prompt Esc can clear a
	// draft or open the rewind menu.
	send_input(input_route(), transmute([]u8)string("\x1b"))
	on_escape()
	return `{"sent":true,"via":"esc"}`
}

rpc_set_model :: proc(model_in: string) -> (string, string) {
	h := hub()
	model := strings.trim_space(model_in)
	if model == "" do return "", "model is empty"
	for r in model {
		if r <= ' ' || r == 0x7f do return "", fmt.tprintf("invalid model name %q", model)
	}
	if len(model) > 128 do return "", "model name is too long"
	if !h.session_started do return "", "the session has not started yet"
	if len(h.dialogs) > 0 do return "", "a dialog is open; answer it first"
	if h.state != "idle" do return "", "cannot switch models while Claude is busy"
	set_meta("model_pending", &h.model_pending, model)
	set_meta("model_error", &h.model_error, "")
	_, err := hub_send_prompt(fmt.tprintf("/model %s", model), "inproc", command = true)
	if err != "" do return "", err
	return fmt.tprintf(`{{"model":"%s","status":"switching"}}`, model), ""
}

EFFORT_LEVELS :: []string{"low", "medium", "high", "xhigh", "max"}

// `/effort LEVEL`, as typed at the terminal. Claude Code also saves it as the
// default for new sessions, as it does there.
rpc_set_effort :: proc(level_in: string) -> (string, string) {
	h := hub()
	level := strings.to_lower(strings.trim_space(level_in), context.temp_allocator)
	known := false
	for l in EFFORT_LEVELS do if l == level do known = true
	if !known do return "", fmt.tprintf("unknown effort %q, expected low, medium, high, xhigh or max", level_in)
	if !h.session_started do return "", "the session has not started yet"
	if len(h.dialogs) > 0 do return "", "a dialog is open; answer it first"
	if h.state != "idle" do return "", "cannot change effort while Claude is busy"
	_, err := hub_send_prompt(fmt.tprintf("/effort %s", level), "inproc", command = true)
	if err != "" do return "", err
	return fmt.tprintf(`{{"effort":"%s","status":"switching"}}`, level), ""
}

IMAGE_TYPES :: []string{"png", "jpg", "jpeg", "gif", "webp"}

// Images for a prompt: `{"path": "..."}` for a file, or `{"data": base64,
// "media_type": "image/png"}`, which is written to a private file that lives as
// long as the session.
@(private = "file")
prompt_images :: proc(list: Array) -> ([]string, string) {
	out := make([dynamic]string, context.temp_allocator)
	for item in list {
		if path := jstr(item, "path"); path != "" {
			ext := strings.to_lower(path[strings.last_index_byte(path, '.') + 1:], context.temp_allocator)
			image := false
			for t in IMAGE_TYPES do if t == ext do image = true
			if !image do return nil, fmt.tprintf("%s is not a png, jpeg, gif or webp image", path)
			if !os.is_file(path) do return nil, fmt.tprintf("no image file at %s", path)
			append(&out, path)
			continue
		}
		data := jstr(item, "data")
		if data == "" do return nil, "each image is {\"path\": ...} or {\"data\": base64, \"media_type\": ...}"
		ext := ""
		switch jstr(item, "media_type") {
		case "image/png", "": ext = "png"
		case "image/jpeg": ext = "jpg"
		case "image/gif": ext = "gif"
		case "image/webp": ext = "webp"
		case: return nil, fmt.tprintf("unsupported media_type %q", jstr(item, "media_type"))
		}
		bytes, err := base64.decode(data, allocator = context.temp_allocator)
		if err != nil do return nil, "image data is not valid base64"
		app.next_image += 1
		path := fmt.aprintf("%s/%d.img-%d.%s", run_dir(), c_getpid(), app.next_image, ext)
		if !write_private_file(path, string(bytes)) do return nil, "could not write the image file"
		append(&app.temp_files, path)
		append(&out, path)
	}
	return out[:], ""
}

@(private = "file")
rpc_resize :: proc(params: Value) -> string {
	cols, ok1 := jint(params, "cols")
	rows, ok2 := jint(params, "rows")
	if !ok1 || !ok2 || cols < 10 || rows < 4 || cols > 1000 || rows > 500 do return "cols and rows are required"
	if app.mode == .Interactive do return "the real terminal owns the size of an interactive session"
	set_winsize(app.pty_fd, Winsize{rows = u16(rows), cols = u16(cols)})
	screen_resize(app.screen, int(cols), int(rows))
	if app.child_pid > 0 do c_kill(app.child_pid, SIGWINCH)
	ev := event("term.resize")
	jw_int(&ev.w, "cols", cols)
	jw_int(&ev.w, "rows", rows)
	event_send(ev)
	return ""
}

screen_json :: proc(ansi: bool) -> string {
	s := app.screen
	b := strings.builder_make(context.temp_allocator)
	w := jw_make(&b)
	jw_obj(&w)
	jw_int(&w, "cols", i64(s.cols))
	jw_int(&w, "rows", i64(s.rows))
	jw_obj_key(&w, "cursor")
	jw_int(&w, "x", i64(s.cx))
	jw_int(&w, "y", i64(s.cy))
	jw_bool(&w, "visible", s.cursor_visible)
	jw_end_obj(&w)
	jw_bool(&w, "alt_screen", s.using_alt)
	jw_bool(&w, "bracketed_paste", s.bracketed_paste)
	jw_arr_key(&w, "lines")
	for line in screen_lines(s) do jw_str_item(&w, line)
	jw_end_arr(&w)
	if mode, ok := detect_mode(s); ok do jw_str(&w, "permission_mode", mode)
	if ansi do jw_str(&w, "ansi", screen_render(s))
	jw_end_obj(&w)
	return strings.to_string(b)
}

// ---------- Keys ----------

key_bytes :: proc(name_in: string) -> (string, bool) {
	name := strings.to_lower(strings.trim_space(name_in), context.temp_allocator)
	switch name {
	case "enter", "return": return "\r", true
	case "esc", "escape": return "\x1b", true
	case "tab": return "\t", true
	case "shift+tab", "backtab": return "\x1b[Z", true
	case "up": return app.screen.app_cursor ? "\x1bOA" : "\x1b[A", true
	case "down": return app.screen.app_cursor ? "\x1bOB" : "\x1b[B", true
	case "right": return app.screen.app_cursor ? "\x1bOC" : "\x1b[C", true
	case "left": return app.screen.app_cursor ? "\x1bOD" : "\x1b[D", true
	case "home": return "\x1b[H", true
	case "end": return "\x1b[F", true
	case "pageup": return "\x1b[5~", true
	case "pagedown": return "\x1b[6~", true
	case "backspace": return "\x7f", true
	case "delete": return "\x1b[3~", true
	case "space": return " ", true
	case "shift+enter": return "\x1b\r", true
	}
	if strings.has_prefix(name, "ctrl+") && len(name) == 6 {
		ch := name[5]
		if ch >= 'a' && ch <= 'z' {
			out := make([]u8, 1, context.temp_allocator)
			out[0] = ch - 'a' + 1
			return string(out), true
		}
		switch ch {
		case '[': return "\x1b", true
		case '\\': return "\x1c", true
		case ']': return "\x1d", true
		case '_': return "\x1f", true
		}
	}
	if strings.has_prefix(name, "alt+") && len(name) > 4 {
		rest, ok := key_bytes(name[4:])
		if !ok && len(name) == 5 do rest, ok = name[4:], true
		if ok do return strings.concatenate({"\x1b", rest}, context.temp_allocator), true
	}
	return "", false
}

// `{"keys": ["esc", {"text": "hi"}, "enter"], "delay_ms": 60}`, `{"text": "..."}` or
// `{"data": "<base64>"}`. Written to the terminal exactly as typed keys would be,
// one item per step.
@(private = "file")
rpc_keys :: proc(params: Value) -> string {
	steps := make([dynamic]string, context.temp_allocator)
	if keys := jarr(params, "keys"); keys != nil {
		for item in keys {
			#partial switch x in item {
			case json.String:
				bytes, ok := key_bytes(string(x))
				if !ok do return fmt.tprintf("unknown key %q (use {\"text\": ...} for literal text)", string(x))
				append(&steps, bytes)
			case Object:
				if t := jstr(item, "text"); t != "" do append(&steps, t)
				else if k := jstr(item, "key"); k != "" {
					bytes, ok := key_bytes(k)
					if !ok do return fmt.tprintf("unknown key %q", k)
					append(&steps, bytes)
				}
			case:
				return "each key is a name like \"enter\" or {\"text\": \"...\"}"
			}
		}
	} else {
		data, err := param_bytes(params)
		if err != "" do return "pass `keys`, `text` or `data`"
		append(&steps, string(data))
	}
	delay, has_delay := jint(params, "delay_ms")
	if !has_delay do delay = 60
	at: i64 = 0
	for step in steps {
		if at == 0 {
			pty_write(transmute([]u8)step)
			hub_on_terminal_input(transmute([]u8)step)
		} else {
			timer_add(at, .Input, step, .Pty)
		}
		at += max(delay, 1)
	}
	return ""
}

// ---------- Dialogs ----------

@(private = "file")
clean_free_text :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch {
		case r == '\n' || r == '\r' || r == '\t': strings.write_byte(&b, ' ')
		case r < 0x20 || r == 0x7f: continue
		case: strings.write_rune(&b, r)
		}
	}
	return strings.trim_space(strings.to_string(b))
}

// What Claude receives for each question: its text mapped to the chosen labels and
// any free text, comma separated, as the terminal dialog records them.
build_answers :: proc(input: Value, answers: Value) -> (Object, string) {
	out, _, err := build_answers_annotated(input, answers)
	return out, err
}

// Also returns the annotations Claude Code records with answers: a question's
// notes, and the preview of the option picked, as the terminal card sends them.
build_answers_annotated :: proc(input: Value, answers: Value) -> (Object, Object, string) {
	questions := jarr(input, "questions")
	out := make(Object, context.temp_allocator)
	notes := make(Object, context.temp_allocator)
	#partial switch a in answers {
	case Object:
		for q in questions {
			text := jstr(q, "question")
			#partial switch x in a[text] {
			case json.String:
				out[text] = x
			case Array:
				parts := make([dynamic]string, context.temp_allocator)
				for p in x do if s, ok := p.(json.String); ok do append(&parts, string(s))
				out[text] = json.String(strings.join(parts[:], ", ", context.temp_allocator))
			case:
				return nil, nil, fmt.tprintf("no answer for %q", text)
			}
		}
	case Array:
		if len(a) != len(questions) do return nil, nil, fmt.tprintf("expected %d answers, got %d", len(questions), len(a))
		for q, i in questions {
			text := jstr(q, "question")
			labels := make([dynamic]string, context.temp_allocator)
			for o in jarr(q, "options") do append(&labels, jstr(o, "label"))
			parts := make([dynamic]string, context.temp_allocator)
			for sel in jarr(a[i], "selected") {
				label, _ := sel.(json.String)
				found := false
				for l in labels do if l == string(label) do found = true
				if !found do return nil, nil, fmt.tprintf("%q has no option %q", text, string(label))
				append(&parts, string(label))
			}
			selected := len(parts)
			other := clean_free_text(jstr(a[i], "other"))
			if other != "" do append(&parts, other)
			if jbool(q, "multiSelect") {
				if len(parts) == 0 do return nil, nil, fmt.tprintf("%q needs at least one answer", text)
			} else if !((selected == 1 && other == "") || (selected == 0 && other != "")) {
				return nil, nil, fmt.tprintf("%q needs exactly one answer: one option or free text", text)
			}
			out[text] = json.String(strings.join(parts[:], ", ", context.temp_allocator))
			annotation := make(Object, context.temp_allocator)
			if note := clean_free_text(jstr(a[i], "notes")); note != "" do annotation["notes"] = json.String(note)
			if selected == 1 {
				for o in jarr(q, "options") {
					if jstr(o, "label") == parts[0] {
						if preview := jstr(o, "preview"); preview != "" do annotation["preview"] = json.String(preview)
					}
				}
			}
			if len(annotation) > 0 do notes[text] = annotation
		}
	case:
		return nil, nil, "answers is required: a list with {\"selected\": [labels], \"other\": text} per question, or an object of question to answer"
	}
	return out, notes, ""
}

// Claude Code's own wording when a person refuses a call at the terminal, so a
// refusal over RPC reads to Claude exactly like one typed there.
REFUSED :: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file)."
REFUSED_STOP :: REFUSED + " STOP what you are doing and wait for the user to tell you how to proceed."
REFUSED_SAID :: REFUSED + " To tell you how to proceed, the user said:\n"

// What Claude reads for a refusal with feedback, as the terminal's "Tell Claude what
// to do differently" puts it.
@(private = "file")
refusal :: proc(message: string, interrupt: bool) -> string {
	if message != "" do return strings.concatenate({REFUSED_SAID, message}, context.temp_allocator)
	return interrupt ? REFUSED_STOP : REFUSED
}

@(private = "file")
decision_json :: proc(behavior: string, updated_input: Value, updated_permissions: string, message: string, interrupt: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := jw_make(&b)
	jw_obj(&w)
	jw_obj_key(&w, "hookSpecificOutput")
	jw_str(&w, "hookEventName", "PermissionRequest")
	jw_obj_key(&w, "decision")
	jw_str(&w, "behavior", behavior)
	if updated_input != nil do jw_value(&w, "updatedInput", updated_input)
	if updated_permissions != "" do jw_raw(&w, "updatedPermissions", updated_permissions)
	if message != "" do jw_str(&w, "message", message)
	if interrupt do jw_bool(&w, "interrupt", true)
	jw_end_obj(&w)
	jw_end_obj(&w)
	jw_end_obj(&w)
	return strings.to_string(b)
}

// Answers the card on screen by choice number: `terminal` dialogs, and dialogs whose
// hook has gone. `{"option": N, "text"?: "..."}`, or `{"decision": "cancel"}` for Esc.
@(private = "file")
respond_on_screen :: proc(d: ^Dialog, params: Value) -> (string, string) {
	option := 0
	if n, ok := jint(params, "option"); ok {
		option = int(n)
		if option < 1 do return "", "option counts from 1"
	} else if jstr(params, "decision") != "cancel" {
		return "", "answer a card with {\"option\": N} (its choice number, optionally with \"text\" for a choice that takes text) or {\"decision\": \"cancel\"}"
	}
	if err := answer_card(option, clean_free_text(jstr(params, "text"))); err != "" do return "", err
	status := option == 0 ? "cancelled" : "answered"
	dialog_id := strings.clone(d.id, context.temp_allocator)
	if d.kind != "terminal" {
		// A hook dialog closes when Claude Code reports the tool's outcome.
		return fmt.tprintf(`{{"dialog_id":"%s","status":"sent"}}`, dialog_id), ""
	}
	settle_begin(d)
	close_dialog(d, status, "rpc", "")
	return fmt.tprintf(`{{"dialog_id":"%s","status":"%s"}}`, dialog_id, status), ""
}

rpc_dialog_respond :: proc(params: Value) -> (string, string) {
	id := jstr(params, "id")
	if id == "" do id = jstr(params, "dialog_id")
	d := find_dialog(id)
	if d == nil do return "", fmt.tprintf("no open dialog %q", id)
	if d.kind == "terminal" || (d.hook_client == 0 && jhas(params, "option")) {
		return respond_on_screen(d, params)
	}
	if d.hook_client == 0 {
		return "", "this dialog is no longer held by zclaude, so only its card on the terminal can answer it: pick a choice with {\"option\": N} (see `screen`), or use `keys`"
	}
	input, _ := parse_json(d.input)
	decision := jstr(params, "decision")
	message := jstr(params, "message")
	interrupt := jbool(params, "interrupt")
	output, status, answers, mode, feedback: string
	switch d.kind {
	case "question":
		if decision == "cancel" || decision == "deny" || decision == "decline" {
			if message == "" do message = "The user declined to answer these questions."
			output = decision_json("deny", nil, "", message, interrupt)
			status = "cancelled"
		} else {
			// `response` is the card's free reply to the questions as a whole.
			response := strings.trim_space(jstr(params, "response"))
			answer_map, annotations, err := build_answers_annotated(input, jget(params, "answers"))
			if err != "" && !(response != "" && jget(params, "answers") == nil) do return "", err
			if answer_map == nil do answer_map = make(Object, context.temp_allocator)
			updated, _ := input.(Object)
			copy_obj := make(Object, context.temp_allocator)
			for k, v in updated do copy_obj[k] = v
			copy_obj["answers"] = answer_map
			if len(annotations) > 0 do copy_obj["annotations"] = annotations
			if response != "" do copy_obj["response"] = json.String(response)
			output = decision_json("allow", copy_obj, "", "", false)
			status = "answered"
			answers = to_json(answer_map, context.temp_allocator)
		}
	case "permission":
		switch decision {
		case "allow", "allow_always":
			updated_input: Value = nil
			if ui, ok := jobj(params, "updated_input"); ok do updated_input = ui
			perms := ""
			if p := jget(params, "updated_permissions"); p != nil {
				perms = to_json(p, context.temp_allocator)
			} else if decision == "allow_always" {
				// The card's "Yes, and always allow ..." choice applies these.
				if d.suggestions == "" || d.suggestions == "[]" do return "", "this dialog offers no rule to always allow; use \"allow\""
				perms = d.suggestions
			}
			// "Yes, and switch to auto mode", or any other mode, with the allow.
			if m := jstr(params, "mode"); m != "" {
				switch m {
				case "default", "acceptEdits", "auto", "dontAsk", "plan", "bypassPermissions":
				case:
					return "", fmt.tprintf("unknown mode %q", m)
				}
				set_mode := fmt.tprintf(`{{"type":"setMode","mode":"%s","destination":"session"}}`, m)
				perms = perms == "" || perms == "[]" ? fmt.tprintf("[%s]", set_mode) : fmt.tprintf("%s,%s]", perms[:len(perms) - 1], set_mode)
				mode = m
			}
			output = decision_json("allow", updated_input, perms, "", false)
			status = "allowed"
		case "deny":
			output = decision_json("deny", nil, "", refusal(message, interrupt), interrupt)
			status = "denied"
		case:
			return "", "decision must be \"allow\", \"allow_always\" or \"deny\""
		}
	case "plan":
		switch decision {
		case "approve", "allow":
			// Without a mode, the first one the card offers, as Enter would pick. Before
			// the card is drawn none is known, and Claude Code restores the mode the
			// session had before plan mode.
			mode = jstr(params, "mode")
			if mode == "" && len(d.modes) > 0 do mode = d.modes[0]
			perms := ""
			if mode != "" {
				switch mode {
				case "default", "acceptEdits", "auto", "dontAsk":
				case "bypassPermissions":
					offered := false
					for m in d.modes do if m == mode do offered = true
					if !offered do return "", "this session does not offer bypassPermissions (start claude with --allow-dangerously-skip-permissions)"
				case:
					return "", fmt.tprintf("unknown mode %q, expected one of the dialog's modes: default, acceptEdits, auto, dontAsk or bypassPermissions", mode)
				}
				perms = fmt.tprintf(`[{{"type":"setMode","mode":"%s","destination":"session"}}]`, mode)
			}
			// Tools that need a person (ExitPlanMode, AskUserQuestion) only take a hook's
			// allow when it carries the input, which is also how an edited plan goes back.
			updated := make(Object, context.temp_allocator)
			if obj, is_obj := input.(Object); is_obj do for k, v in obj do updated[k] = v
			if edited, has := jget(params, "plan").(json.String); has {
				if strings.trim_space(string(edited)) == "" do return "", "plan is empty"
				updated["plan"] = edited
			}
			output = decision_json("allow", updated, perms, "", false)
			status = "approved"
			feedback = message
		case "deny", "reject":
			// The card's "Tell Claude what to change". Without feedback, Claude is told
			// to keep planning, unless the turn is interrupted too (Esc on the card).
			reason := refusal(message, interrupt)
			if message == "" && !interrupt do reason = strings.concatenate({REFUSED, " Stay in plan mode: ask the user what to change in the plan, revise it, and present it again."}, context.temp_allocator)
			output = decision_json("deny", nil, "", reason, interrupt)
			status = "rejected"
		case:
			return "", "decision must be \"approve\" (with an optional mode, plan or message) or \"reject\" (with an optional message)"
		}
	case "elicitation":
		action := jstr(params, "action")
		if action == "" do action = decision
		switch action {
		case "accept", "decline", "cancel":
		case:
			return "", "action must be \"accept\", \"decline\" or \"cancel\""
		}
		b := strings.builder_make(context.temp_allocator)
		w := jw_make(&b)
		jw_obj(&w)
		jw_obj_key(&w, "hookSpecificOutput")
		jw_str(&w, "hookEventName", "Elicitation")
		jw_str(&w, "action", action)
		if content := jget(params, "content"); content != nil do jw_value(&w, "content", content)
		jw_end_obj(&w)
		jw_end_obj(&w)
		output = strings.to_string(b)
		status = action == "accept" ? "accepted" : action == "decline" ? "declined" : "cancelled"
	}
	dialog_id := strings.clone(d.id, context.temp_allocator)
	close_dialog(d, status, "rpc", answers, output)
	b := strings.builder_make(context.temp_allocator)
	w := jw_make(&b)
	jw_obj(&w)
	jw_str(&w, "dialog_id", dialog_id)
	jw_str(&w, "status", status)
	if mode != "" do jw_str(&w, "mode", mode)
	if feedback != "" {
		// A hook can't attach feedback to an approval, so it follows as the next
		// prompt, typed once the card has gone. Claude reads it before going on.
		if p, err := hub_send_prompt(feedback, "inproc"); err == "" do jw_str(&w, "prompt_id", p.id)
	}
	jw_end_obj(&w)
	return strings.to_string(b), ""
}
