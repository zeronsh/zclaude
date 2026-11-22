package zclaude

// Turns Claude Code transcript JSONL lines into the conversation entries forwarded
// to consumers.
//
// The transcript also records system prompts, account details and raw API requests.
// Only `user`, `assistant`, a few `system` lines and prompts absorbed mid-turn are
// forwarded. Everything here allocates from the temporary allocator: entries are
// emitted as events immediately and never kept.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Text Claude Code puts in front of a prompt delivered by the rewake hook.
REWAKE_PREFIX :: "Prompt sent through the zclaude RPC API:"
MAX_STRING :: 32 * 1024

Entry :: struct {
	uuid:       string,
	session_id: string,
	role:       string,
	// terminal | external | notification | tool_result | command | meta | interrupt | system | assistant
	origin:     string,
	timestamp:  string,
	text:       string,
	// JSON array of content blocks, with large payloads removed.
	blocks:     string,
	model:      string,
	// The API message id, which links an assistant entry to its live stream.
	message_id: string,
	sidechain:  bool,
}

parse_line :: proc(line: string) -> (e: Entry, ok: bool) {
	v := parse_json(line) or_return
	kind := jstr(v, "type")
	parsed: Parsed
	switch kind {
	case "user":
		parsed = parse_user(v) or_return
	case "assistant":
		parsed = parse_assistant(v) or_return
	case "system":
		parsed = parse_system(v) or_return
	case "attachment":
		parsed = parse_queued(v) or_return
	case:
		return {}, false
	}
	uuid := jstr(v, "uuid")
	if uuid == "" do return {}, false
	e = Entry {
		uuid       = uuid,
		session_id = jstr(v, "sessionId"),
		role       = parsed.role,
		origin     = parsed.origin,
		timestamp  = jstr(v, "timestamp"),
		text       = parsed.text,
		blocks     = to_json(parsed.blocks, context.temp_allocator),
		model      = parsed.model,
		message_id = kind == "assistant" ? jstr(v, "message", "id") : "",
		sidechain  = jbool(v, "isSidechain"),
	}
	return e, true
}

// Recognizes Claude Code's `{"type":"repl-mode","replMode":bool}` metadata line.
parse_repl_mode :: proc(line: string) -> (enabled: bool, ok: bool) {
	if !strings.contains(line, "\"repl-mode\"") do return false, false
	v := parse_json(line) or_return
	if jstr(v, "type") != "repl-mode" do return false, false
	b, is_bool := jget(v, "replMode").(json.Boolean)
	return bool(b), is_bool
}

// Plain text inside `<local-command-stdout>…</local-command-stdout>`, ANSI removed.
parse_command_stdout :: proc(text: string) -> (string, bool) {
	OPEN :: "<local-command-stdout>"
	CLOSE :: "</local-command-stdout>"
	i := strings.index(text, OPEN)
	if i < 0 do return "", false
	rest := text[i + len(OPEN):]
	end := strings.last_index(rest, CLOSE)
	if end < 0 do end = len(rest)
	return strings.trim_space(strip_ansi(rest[:end])), true
}

// The active model from a `/model` command's output, such as
// "Set model to `Sonnet 5.5` and saved as your default".
parse_model_switch_output :: proc(text: string) -> (model: string, ok: bool) {
	stdout := parse_command_stdout(text) or_return
	first := stdout
	if nl := strings.index_byte(stdout, '\n'); nl >= 0 do first = stdout[:nl]
	first = strings.trim_space(first)
	for prefix in ([]string{"Set model to ", "Kept model as ", "Current model: "}) {
		if strings.has_prefix(first, prefix) {
			return extract_model_token(first[len(prefix):])
		}
	}
	if i := strings.index(first, "model set to "); i >= 0 {
		return extract_model_token(first[i + len("model set to "):])
	}
	return "", false
}

// The level from `/effort`'s output, such as "Set effort level to high (saved as
// your default for new sessions)".
parse_effort_output :: proc(text: string) -> (level: string, ok: bool) {
	stdout := parse_command_stdout(text) or_return
	PREFIX :: "Set effort level to "
	if !strings.has_prefix(stdout, PREFIX) do return "", false
	rest := stdout[len(PREFIX):]
	end := 0
	for end < len(rest) && rest[end] >= 'a' && rest[end] <= 'z' do end += 1
	return rest[:end], end > 0
}

@(private = "file")
extract_model_token :: proc(rest_in: string) -> (string, bool) {
	rest := strings.trim_left_space(rest_in)
	if strings.has_prefix(rest, "`") {
		after := rest[1:]
		end := strings.index_byte(after, '`')
		if end < 0 do return "", false
		token := strings.trim_space(after[:end])
		return token, token != ""
	}
	token := rest
	for sep in ([]string{" and ", " for ", " · "}) {
		if i := strings.index(token, sep); i >= 0 do token = token[:i]
	}
	token = strings.trim_right(token, ".")
	token = strings.trim_space(token)
	return token, token != ""
}

strip_ansi :: proc(input: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(input) {
		if input[i] == 0x1b && i + 1 < len(input) && input[i + 1] == '[' {
			i += 2
			for i < len(input) {
				c := input[i]
				i += 1
				if c >= '@' && c <= '~' do break
			}
			continue
		}
		strings.write_byte(&b, input[i])
		i += 1
	}
	return strings.to_string(b)
}

// `/command args` from Claude Code's `<command-name>` transcript entry.
parse_command_invocation :: proc(text: string) -> (string, bool) {
	OPEN :: "<command-name>"
	CLOSE :: "</command-name>"
	start := strings.index(text, OPEN)
	if start < 0 do return "", false
	start += len(OPEN)
	end := strings.index(text[start:], CLOSE)
	if end < 0 do return "", false
	name := strings.trim_space(text[start:start + end])
	if name == "" do return "", false
	args := ""
	if a := strings.index(text, "<command-args>"); a >= 0 {
		s := a + len("<command-args>")
		if e := strings.index(text[s:], "</command-args>"); e >= 0 {
			args = strings.trim_space(text[s:s + e])
		}
	}
	if args == "" do return name, true
	return fmt.tprintf("%s %s", name, args), true
}

is_hex4 :: proc(s: string) -> bool {
	if len(s) != 4 do return false
	for c in transmute([]u8)s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) do return false
	}
	return true
}

// Removes Claude Code's `<pasted_content id="xxxx">…</pasted_content id="xxxx">`
// wrappers from bracketed-paste prompts, so they read cleanly and match prompts
// sent through the `inproc` transport.
unwrap_pasted_content :: proc(raw: string) -> string {
	OPEN_PREFIX :: "<pasted_content id=\""
	parts := make([dynamic]string, context.temp_allocator)
	has_block := false
	cursor := 0
	search := 0
	for {
		rel := strings.index(raw[search:], OPEN_PREFIX)
		if rel < 0 do break
		open_pos := search + rel
		id_start := open_pos + len(OPEN_PREFIX)
		if id_start + 4 > len(raw) do break
		id := raw[id_start:id_start + 4]
		if !is_hex4(id) || !strings.has_prefix(raw[id_start + 4:], "\">\n") {
			search = id_start
			continue
		}
		body_start := id_start + 4 + 3
		close_tag := fmt.tprintf("</pasted_content id=\"%s\">", id)
		close_needle := fmt.tprintf("\n%s", close_tag)
		close_rel := strings.index(raw[body_start - 1:], close_needle)
		if close_rel < 0 do break
		close_pos := (body_start - 1) + close_rel + 1
		body_end := max(close_pos - 1, 0)
		body := body_end >= body_start ? raw[body_start:body_end] : ""

		before := open_pos
		for _ in 0 ..< 2 {
			if before > cursor && raw[before - 1] == '\n' do before -= 1
		}
		if before > cursor do append(&parts, raw[cursor:before])
		unescaped, _ := strings.replace_all(body, "<\\pasted_content", "<pasted_content", context.temp_allocator)
		unescaped, _ = strings.replace_all(unescaped, "<\\/pasted_content", "</pasted_content", context.temp_allocator)
		append(&parts, unescaped)
		has_block = true

		cursor = close_pos + len(close_tag)
		for _ in 0 ..< 2 {
			if cursor < len(raw) && raw[cursor] == '\n' do cursor += 1
		}
		search = cursor
	}
	if !has_block do return raw
	if cursor < len(raw) do append(&parts, raw[cursor:])
	joined := strings.join(parts[:], "\n\n", context.temp_allocator)
	return strings.trim_space(joined)
}

@(private = "file")
Parsed :: struct {
	role, origin, text: string,
	blocks:             Value,
	model:              string,
}

@(private = "file")
parse_user :: proc(v: Value) -> (Parsed, bool) {
	content := jget(v, "message", "content")
	if content == nil do return {}, false
	return classify_user(content, jbool(v, "isMeta")), true
}

// A prompt that arrives during a turn is recorded as an attachment, not as a `user`
// line. Every other attachment type is private context and is dropped.
@(private = "file")
parse_queued :: proc(v: Value) -> (Parsed, bool) {
	if jstr(v, "attachment", "type") != "queued_command" do return {}, false
	switch jstr(v, "attachment", "commandMode") {
	case "prompt", "task-notification":
		prompt := jget(v, "attachment", "prompt")
		if prompt == nil do return {}, false
		return classify_user(prompt, false), true
	}
	return {}, false
}

@(private = "file")
text_block :: proc(text: string) -> Value {
	obj := make(Object, context.temp_allocator)
	obj["type"] = json.String("text")
	obj["text"] = json.String(text)
	arr := make(Array, 1, context.temp_allocator)
	arr[0] = obj
	return arr
}

@(private = "file")
classify_user :: proc(content: Value, meta: bool) -> Parsed {
	blocks: Value
	if s, is_str := content.(json.String); is_str {
		blocks = text_block(truncate(unwrap_pasted_content(string(s))))
	} else {
		blocks = slim(content)
	}
	arr, _ := blocks.(Array)
	has_tool_result := false
	for b in arr {
		if jstr(b, "type") == "tool_result" do has_tool_result = true
	}
	if !has_tool_result {
		for &b in arr {
			obj, is_obj := b.(Object)
			if !is_obj || jstr(b, "type") != "text" do continue
			s := jstr(b, "text")
			cleaned := unwrap_pasted_content(s)
			if cleaned != s do obj["text"] = json.String(cleaned)
		}
	}
	text := blocks_text(arr)
	origin: string
	switch {
	case has_tool_result:
		origin = "tool_result"
	case meta:
		origin = "meta"
	case strings.has_prefix(text, "<task-notification>"):
		origin = "notification"
		text = rewake_text(text)
	case strings.has_prefix(text, "[Request interrupted"):
		origin = "interrupt"
	case strings.has_prefix(text, "<command-") || strings.has_prefix(text, "<local-command"):
		origin = "command"
	case:
		origin = "terminal"
	}
	return Parsed{role = "user", origin = origin, text = text, blocks = blocks}
}

@(private = "file")
parse_assistant :: proc(v: Value) -> (Parsed, bool) {
	content := jget(v, "message", "content")
	if content == nil do return {}, false
	slimmed, is_arr := slim(content).(Array)
	if !is_arr do return {}, false
	kept := make(Array, 0, len(slimmed), context.temp_allocator)
	for b in slimmed {
		// Signature-only thinking carries nothing to show.
		if jstr(b, "type") == "thinking" && jstr(b, "thinking") == "" do continue
		append(&kept, b)
	}
	if len(kept) == 0 do return {}, false
	return Parsed{role = "assistant", origin = "assistant", text = blocks_text(kept), blocks = kept, model = jstr(v, "message", "model")}, true
}

@(private = "file")
parse_system :: proc(v: Value) -> (Parsed, bool) {
	switch jstr(v, "subtype") {
	case "compact_boundary", "api_error":
		text := jstr(v, "content")
		return Parsed{role = "system", origin = "system", text = text, blocks = text_block(text)}, true
	case "local_command":
		// Newer builds record slash commands and their output this way.
		text := jstr(v, "content")
		if text == "" do return {}, false
		return Parsed{role = "user", origin = "command", text = text, blocks = text_block(text)}, true
	}
	return {}, false
}

@(private = "file")
blocks_text :: proc(blocks: Array) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for b in blocks {
		if jstr(b, "type") == "text" do append(&parts, jstr(b, "text"))
	}
	return strings.join(parts[:], "\n", context.temp_allocator)
}

// Pulls the prompt out of the wrapper Claude Code puts around a rewake.
rewake_text :: proc(raw: string) -> string {
	OPEN :: "<system-reminder>"
	CLOSE :: "</system-reminder>"
	start := strings.index(raw, OPEN)
	if start < 0 do return raw
	body := raw[start + len(OPEN):]
	if end := strings.last_index(body, CLOSE); end >= 0 do body = body[:end]
	body = strings.trim_space(body)
	if i := strings.index(body, REWAKE_PREFIX); i >= 0 {
		return strings.trim_space(body[i + len(REWAKE_PREFIX):])
	}
	// Claude Code ignored rewakeMessage and used its default wording.
	DEFAULT :: "Stop hook blocking error from command "
	if strings.has_prefix(body, DEFAULT) {
		rest := body[len(DEFAULT):]
		if i := strings.index(rest, "\": "); i >= 0 do return strings.trim_space(rest[i + 3:])
	}
	return body
}

// Drops signatures and image data and caps long strings, so one huge tool result
// can't flood consumers.
slim :: proc(v: Value) -> Value {
	#partial switch x in v {
	case json.String:
		return json.String(truncate(string(x)))
	case Array:
		out := make(Array, len(x), context.temp_allocator)
		for item, i in x do out[i] = slim(item)
		return out
	case Object:
		if t, _ := x["type"].(json.String); t == "image" {
			o := make(Object, context.temp_allocator)
			o["type"] = json.String("image")
			o["omitted"] = json.Boolean(true)
			return o
		}
		o := make(Object, len(x), context.temp_allocator)
		for k, val in x {
			if k == "signature" do continue
			o[k] = slim(val)
		}
		return o
	}
	return v
}

truncate :: proc(s: string) -> string {
	if len(s) <= MAX_STRING do return s
	end := MAX_STRING
	for end > 0 && s[end] & 0xC0 == 0x80 do end -= 1
	return fmt.tprintf("%s… [truncated %d bytes]", s[:end], len(s) - end)
}
