package zclaude

// Builds the hook settings injected into Claude Code, and implements the short-lived
// `zclaude __hook` processes those hooks run.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Reported so the session can track state and find the transcript.
OBSERVED_HOOKS :: []string {
	"SessionStart",
	"UserPromptSubmit",
	"PreToolUse",
	"PostToolUse",
	"PostToolUseFailure",
	"PermissionDenied",
	"Notification",
	"SubagentStart",
	"SubagentStop",
	"PreCompact",
	"PostCompact",
	"PostModelSwitch",
	"ElicitationResult",
	"Stop",
	"StopFailure",
	"SessionEnd",
}

// Events that make sure a rewake waiter is armed. `Stop` doesn't fire after an
// interrupt, so the start of each turn arms one as well.
ARMING_HOOKS :: []string{"SessionStart", "UserPromptSubmit", "Stop", "StopFailure"}

// Held hooks wait for a consumer's answer. Node timers overflow past 24.8 days and an
// overflowed timer fires at once, so this stays well below that.
HELD_TIMEOUT_SECS :: 14 * 24 * 3600

shell_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	escaped, _ := strings.replace_all(s, "'", "'\\''", context.temp_allocator)
	return strings.concatenate({"'", escaped, "'"}, allocator)
}

// Merges zclaude's hooks into the user's own `--settings` value, if any. Claude Code
// takes a single `--settings`, so they share one.
build_settings :: proc(exe, socket: string, user: string) -> (string, string) {
	settings: Object
	if strings.trim_space(user) == "" {
		settings = make(Object, context.temp_allocator)
	} else {
		raw := user
		if !strings.has_prefix(strings.trim_left_space(user), "{") {
			data, err := os.read_entire_file(user, context.temp_allocator)
			if err != nil do return "", fmt.tprintf("could not read --settings file %s", user)
			raw = string(data)
		}
		v, ok := parse_json(raw)
		obj, is_obj := v.(Object)
		if !ok || !is_obj do return "", "--settings must be a JSON object"
		settings = obj
	}
	set_default :: proc(o: ^Object, key: string, v: Value) {
		if key not_in o^ do o[key] = v
	}
	// Without this the API returns signatures only, leaving no thinking to show.
	set_default(&settings, "showThinkingSummaries", json.Boolean(true))
	// Interactive confirmation modals that would otherwise stop a remote session.
	set_default(&settings, "skipDangerousModePermissionPrompt", json.Boolean(true))
	set_default(&settings, "skipAutoPermissionPrompt", json.Boolean(true))
	set_default(&settings, "skipWorkflowUsageWarning", json.Boolean(true))

	hooks, has_hooks := settings["hooks"].(Object)
	if !has_hooks do hooks = make(Object, context.temp_allocator)
	qexe, qsock := shell_quote(exe), shell_quote(socket)
	add :: proc(hooks: ^Object, event: string, hook: Object) {
		list, _ := hooks[event].(Array)
		group := make(Object, context.temp_allocator)
		inner := make(Array, 1, context.temp_allocator)
		inner[0] = hook
		group["hooks"] = inner
		next := make(Array, 0, len(list) + 1, context.temp_allocator)
		append(&next, ..list[:])
		append(&next, group)
		hooks[event] = next
	}
	command :: proc(cmd: string, timeout: i64) -> Object {
		h := make(Object, context.temp_allocator)
		h["type"] = json.String("command")
		h["command"] = json.String(cmd)
		h["timeout"] = json.Integer(timeout)
		return h
	}
	for event in OBSERVED_HOOKS {
		add(&hooks, event, command(fmt.tprintf("%s __hook event %s", qexe, qsock), 5))
	}
	add(&hooks, "PreModelSwitch", command(fmt.tprintf("%s __hook pre-model-switch %s", qexe, qsock), 5))
	// Held until a consumer decides, while the TUI shows the same dialog.
	add(&hooks, "PermissionRequest", command(fmt.tprintf("%s __hook permission %s", qexe, qsock), HELD_TIMEOUT_SECS))
	add(&hooks, "Elicitation", command(fmt.tprintf("%s __hook elicitation %s", qexe, qsock), HELD_TIMEOUT_SECS))
	for event in ARMING_HOOKS {
		h := command(fmt.tprintf("%s __hook wait %s", qexe, qsock), HELD_TIMEOUT_SECS)
		h["asyncRewake"] = json.Boolean(true)
		// Marked internal by Claude Code. It falls back to generic wording without
		// them, which the transcript parser also understands.
		h["rewakeMessage"] = json.String(REWAKE_PREFIX)
		h["rewakeSummary"] = json.String("External prompt via zclaude")
		add(&hooks, event, h)
	}
	settings["hooks"] = hooks
	return to_json(settings), ""
}

// `zclaude __hook <event|permission|elicitation|pre-model-switch|wait> <socket>`.
// A failure here must never disturb the Claude session, so anything unexpected exits
// 0 silently, which leaves every decision to the terminal.
run_hook :: proc(mode, socket: string) -> int {
	input := read_all_stdin()
	method: string
	switch mode {
	case "event": method = "hook.event"
	case "permission": method = "hook.permission"
	case "elicitation": method = "hook.elicitation"
	case "pre-model-switch": method = "hook.pre_model_switch"
	case "wait": method = "hook.wait"
	case: return 0
	}
	fd, ok := connect_unix(socket)
	if !ok do return 0
	params := strings.trim_space(input)
	if !strings.has_prefix(params, "{") do params = "{}"
	req := fmt.tprintf("{{\"id\":1,\"method\":\"%s\",\"params\":%s}}\n", method, params)
	if !write_all(fd, transmute([]u8)req) do return 0
	line := read_line(fd)
	c_close(fd)
	v, parsed := parse_json(line)
	if !parsed do return 0
	if mode == "wait" {
		text := jstr(v, "result", "text")
		if jstr(v, "result", "action") != "deliver" || text == "" do return 0
		// Exit code 2 with the text on stderr is what makes Claude Code wake the model.
		write_all(2, transmute([]u8)text)
		return 2
	}
	if out := jstr(v, "result", "output"); out != "" {
		write_all(1, transmute([]u8)out)
		write_all(1, transmute([]u8)string("\n"))
	}
	return 0
}

read_all_stdin :: proc() -> string {
	b := make([dynamic]u8, context.temp_allocator)
	buf: [65536]u8
	for {
		n := c_read(0, &buf[0], len(buf))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do break
		append(&b, ..buf[:n])
	}
	return string(b[:])
}

// One line from a blocking fd, without the newline. Empty at EOF.
read_line :: proc(fd: i32) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	buf: [65536]u8
	for {
		n := c_read(fd, &buf[0], len(buf))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do break
		for i in 0 ..< int(n) {
			if buf[i] == '\n' {
				append(&b, ..buf[:i])
				return string(b[:])
			}
		}
		append(&b, ..buf[:n])
	}
	return string(b[:])
}
