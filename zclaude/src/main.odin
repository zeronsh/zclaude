package zclaude

// zclaude: run the interactive Claude Code CLI unchanged and drive it from outside.
//
//   zclaude [claude args]            use it exactly like `claude`; a control socket opens
//   zclaude --stdio [claude args]    headless: JSON-RPC on stdin/stdout, no terminal needed
//   zclaude ctl <command>            talk to a running session
//
// Subcommands, `--version`, `-p` and non-terminal use (without --stdio) go straight
// to the real binary.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

AGENT_JS :: #load("agent.js", string)
VERSION :: "0.2.0"

SUBCOMMANDS :: []string {
	"agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp", "plugin",
	"plugins", "purge", "respawn", "rm", "setup-token", "stop", "kill", "ultrareview", "update", "upgrade",
}
// Flags that mean no interactive session starts here, or that hooks won't run.
PASSTHROUGH_FLAGS :: []string{"-p", "--print", "-v", "--version", "-h", "--help", "--bg", "--background", "--desktop", "--bare"}

// Markers that would make Claude think it is nested in another Claude Code session,
// for example when zclaude is started from inside one.
SESSION_ENV :: []string {
	"CLAUDECODE",
	"CLAUDE_PID",
	"CLAUDE_EFFORT",
	"CLAUDE_CODE_ENTRYPOINT",
	"CLAUDE_CODE_EXECPATH",
	"CLAUDE_CODE_SESSION_ID",
	"CLAUDE_CODE_CHILD_SESSION",
	"CLAUDE_CODE_SESSION_ATTENDED",
	"CLAUDE_CODE_MESSAGING_SOCKET",
	"CLAUDE_CODE_MESSAGING_TOKEN",
	"CLAUDE_CODE_FORWARD_SUBAGENT_TEXT",
	"ZCLAUDE_SOCKET_PATH",
}

when ODIN_OS == .Darwin {
	O_WRONLY :: 0x1
	O_CREAT :: 0x200
	O_TRUNC :: 0x400
} else {
	O_WRONLY :: 0x1
	O_CREAT :: 0o100
	O_TRUNC :: 0o1000
}


Options :: struct {
	stdio:     bool,
	socket:    string,
	no_socket: bool,
	cols:      int,
	rows:      int,
	code_mode: bool,
	log:       string,
}

main :: proc() {
	args := os.args[1:]
	if len(args) >= 1 && args[0] == "__hook" {
		mode := len(args) > 1 ? args[1] : ""
		socket := len(args) > 2 ? args[2] : ""
		os.exit(run_hook(mode, socket))
	}
	if len(args) >= 1 && args[0] == "__session" {
		os.exit(run_session(args[1:]))
	}
	if len(args) >= 1 && args[0] == "ctl" {
		os.exit(run_ctl(args[1:]))
	}
	if len(args) == 1 && (args[0] == "--zclaude-version") {
		fmt.println("zclaude", VERSION)
		os.exit(0)
	}
	os.exit(run(args))
}

fail :: proc(format: string, args: ..any) -> int {
	fmt.eprintf("zclaude: ")
	fmt.eprintfln(format, ..args)
	return 1
}

// Takes zclaude's own flags (before `--`) out of `args`.
parse_options :: proc(args: []string) -> (opts: Options, rest: [dynamic]string, err: string) {
	opts.cols, opts.rows = 120, 40
	rest = make([dynamic]string)
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--" {
			append(&rest, ..args[i:])
			break
		}
		switch {
		case a == "--stdio":
			opts.stdio = true
		case a == "--no-socket":
			opts.no_socket = true
		case a == "--code-mode":
			opts.code_mode = true
		case a == "--socket" || a == "--size" || a == "--log":
			if i + 1 >= len(args) {
				err = fmt.tprintf("%s needs a value", a)
				return
			}
			v := args[i + 1]
			i += 1
			switch a {
			case "--socket": opts.socket = v
			case "--log": opts.log = v
			case "--size":
				x := strings.index_byte(v, 'x')
				cols, ok1 := strconv.parse_int(x > 0 ? v[:x] : "")
				rows, ok2 := strconv.parse_int(x > 0 ? v[x + 1:] : "")
				if !ok1 || !ok2 || cols < 20 || rows < 5 {
					err = "--size takes COLSxROWS, for example 120x40"
					return
				}
				opts.cols, opts.rows = cols, rows
			}
		case:
			append(&rest, a)
		}
		i += 1
	}
	return
}

is_executable :: proc(path: string) -> bool {
	if path == "" do return false
	return c_access(strings.clone_to_cstring(path, context.temp_allocator), 1) == 0 && os.is_file(path)
}

// The installed `claude`, found again at every launch so updates are followed.
find_claude :: proc() -> (string, bool) {
	if v := os.get_env("ZCLAUDE_CLAUDE_BIN", context.temp_allocator); v != "" do return v, true
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" do continue
		candidate := strings.concatenate({dir, "/claude"}, context.temp_allocator)
		if is_executable(candidate) do return candidate, true
	}
	home := os.get_env("HOME", context.temp_allocator)
	fallbacks := []string {
		strings.concatenate({home, "/.local/bin/claude"}, context.temp_allocator),
		strings.concatenate({home, "/.claude/local/claude"}, context.temp_allocator),
		strings.concatenate({home, "/.bun/bin/claude"}, context.temp_allocator),
		strings.concatenate({home, "/.npm-global/bin/claude"}, context.temp_allocator),
		"/opt/homebrew/bin/claude",
		"/usr/local/bin/claude",
	}
	for f in fallbacks do if is_executable(f) do return f, true
	return "", false
}

Runtime :: enum {
	Bun,
	Node,
	Both,
}

// Native Bun binaries honor BUN_OPTIONS, npm installs honor NODE_OPTIONS, and shell
// wrappers could start either.
detect_runtime :: proc(bin: string) -> Runtime {
	resolved := realpath(bin, context.temp_allocator)
	fd := c_open(strings.clone_to_cstring(resolved, context.temp_allocator), 0)
	if fd < 0 do return .Both
	head: [128]u8
	n := max(int(c_read(fd, &head[0], len(head))), 0)
	c_close(fd)
	h := head[:n]
	if n >= 4 {
		m := h[:4]
		natives := [][4]u8{{0x7f, 'E', 'L', 'F'}, {0xcf, 0xfa, 0xed, 0xfe}, {0xfe, 0xed, 0xfa, 0xcf}, {0xce, 0xfa, 0xed, 0xfe}, {0xfe, 0xed, 0xfa, 0xce}, {0xca, 0xfe, 0xba, 0xbe}, {0xbe, 0xba, 0xfe, 0xca}}
		for magic in natives {
			if m[0] == magic[0] && m[1] == magic[1] && m[2] == magic[2] && m[3] == magic[3] do return .Bun
		}
	}
	if n >= 2 && h[0] == '#' && h[1] == '!' {
		first := string(h)
		if nl := strings.index_any(first, "\r\n"); nl >= 0 do first = first[:nl]
		first = strings.to_lower(first, context.temp_allocator)
		if strings.contains(first, "node") do return .Node
		if strings.contains(first, "bun") do return .Bun
		return .Both
	}
	if strings.has_suffix(resolved, ".js") || strings.has_suffix(resolved, ".mjs") || strings.has_suffix(resolved, ".cjs") do return .Node
	return .Both
}

is_passthrough :: proc(args: []string) -> bool {
	if len(args) > 0 {
		for s in SUBCOMMANDS do if args[0] == s do return true
	}
	for a in args {
		if a == "--" do break
		for f in PASSTHROUGH_FLAGS do if a == f do return true
	}
	return false
}

// Removes the user's `--settings` from `args` and returns its value.
take_user_settings :: proc(args: ^[dynamic]string) -> string {
	value := ""
	i := 0
	for i < len(args) && args[i] != "--" {
		a := args[i]
		if a == "--settings" && i + 1 < len(args) {
			value = args[i + 1]
			remove_range(args, i, i + 2)
		} else if strings.has_prefix(a, "--settings=") {
			value = a[len("--settings="):]
			ordered_remove(args, i)
		} else {
			i += 1
		}
	}
	return value
}

// `--model` from the arguments, else Claude's settings.json, so consumers see the
// model before the first turn.
initial_model :: proc(args: []string) -> string {
	for i := 0; i < len(args) && args[i] != "--"; i += 1 {
		if args[i] == "--model" && i + 1 < len(args) do return args[i + 1]
		if strings.has_prefix(args[i], "--model=") do return args[i][len("--model="):]
	}
	dir := os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator)
	path := dir != "" ? strings.concatenate({dir, "/settings.json"}, context.temp_allocator) : strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.claude/settings.json"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	v, ok := parse_json(string(data))
	if !ok do return ""
	return jstr(v, "model")
}

is_truthy_env :: proc(name: string) -> bool {
	v := strings.to_lower(strings.trim_space(os.get_env(name, context.temp_allocator)), context.temp_allocator)
	return v != "" && v != "0" && v != "false" && v != "off"
}

// `~/.zclaude/run`, owner-only, because anyone who can reach a socket can drive the session.
run_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	dir := strings.concatenate({home, "/.zclaude/run"})
	os.make_directory_all(dir)
	c_chmod(strings.clone_to_cstring(dir, context.temp_allocator), 0o700)
	return dir
}

// Removes runtime files left by sessions that were killed outright.
sweep_stale :: proc(dir: string) {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for f in files {
		dot := strings.index_byte(f.name, '.')
		if dot <= 0 do continue
		kind := f.name[dot + 1:]
		if kind != "sock" && kind != "agent.cjs" do continue
		pid, ok := strconv.parse_int(f.name[:dot])
		if !ok do continue
		if !process_alive(pid) do c_unlink(strings.clone_to_cstring(f.fullpath, context.temp_allocator))
	}
}

write_private_file :: proc(path, contents: string) -> bool {
	fd := c_open(strings.clone_to_cstring(path, context.temp_allocator), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
	if fd < 0 do return false
	ok := write_all(fd, transmute([]u8)contents)
	c_close(fd)
	return ok
}

// The child's environment: ours, minus nested-session markers, plus `set`.
build_env :: proc(set: []string) -> []string {
	env, _ := os.environ(context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	outer: for kv in env {
		eq := strings.index_byte(kv, '=')
		key := eq >= 0 ? kv[:eq] : kv
		for s in SESSION_ENV do if key == s do continue outer
		for s in set {
			if strings.has_prefix(s, key) && len(s) > len(key) && s[len(key)] == '=' do continue outer
		}
		append(&out, kv)
	}
	for s in set do append(&out, s)
	return out[:]
}

cstrings :: proc(list: []string) -> [^]cstring {
	out := make([]cstring, len(list) + 1, context.temp_allocator)
	for s, i in list do out[i] = strings.clone_to_cstring(s, context.temp_allocator)
	out[len(list)] = nil
	return raw_data(out)
}

// Starts `path argv` as a session leader whose controlling terminal is a new PTY.
spawn_pty :: proc(path: string, argv: []string, env: []string, ws: Winsize, termios: ^posix.termios) -> (master: c.int, pid: c.int, ok: bool) {
	master = c_posix_openpt(O_RDWR | O_NOCTTY)
	if master < 0 do return -1, -1, false
	if c_grantpt(master) != 0 || c_unlockpt(master) != 0 {
		c_close(master)
		return -1, -1, false
	}
	slave_name := strings.clone_to_cstring(string(c_ptsname(master)), context.temp_allocator)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	cargv := cstrings(argv)
	cenv := cstrings(env)
	size := ws
	pid = c_fork()
	if pid < 0 {
		c_close(master)
		return -1, -1, false
	}
	if pid == 0 {
		c_setsid()
		slave := c_open(slave_name, O_RDWR)
		if slave < 0 do c_exit(126)
		c_ioctl(slave, TIOCSCTTY, rawptr(nil))
		if termios != nil do posix.tcsetattr(posix.FD(slave), .TCSANOW, termios)
		c_ioctl(slave, TIOCSWINSZ, &size)
		c_dup2(slave, 0)
		c_dup2(slave, 1)
		c_dup2(slave, 2)
		if slave > 2 do c_close(slave)
		c_close(master)
		for s in ([]c.int{SIGPIPE, SIGTTOU, SIGTTIN, SIGTSTP, SIGINT, SIGHUP, SIGTERM, SIGCHLD, SIGWINCH}) do c_signal(s, SIG_DFL)
		c_execve(cpath, cargv, cenv)
		c_exit(127)
	}
	set_nonblocking(master)
	set_cloexec(master)
	return master, pid, true
}

// ---------- Session setup ----------

Prepared :: struct {
	claude:   string,
	argv:     [dynamic]string, // claude's arguments, with --settings first
	env:      []string,
}

prepare :: proc(opts: Options, args_in: [dynamic]string) -> (p: Prepared, err: string) {
	claude, found := find_claude()
	if !found do return {}, "`claude` was not found on PATH or standard install locations (set ZCLAUDE_CLAUDE_BIN to override)"
	p.claude = strings.clone(claude)
	args := args_in
	user_settings := take_user_settings(&args)

	dir := run_dir()
	sweep_stale(dir)
	pid := int(c_getpid())
	app.socket_path = opts.socket != "" ? strings.clone(opts.socket) : fmt.aprintf("%s/%d.sock", dir, pid)
	if !opts.no_socket {
		fd, ok := listen_unix(app.socket_path)
		if !ok do return {}, fmt.tprintf("could not listen on %s", app.socket_path)
		app.listen_fd = fd
	} else {
		app.listen_fd = -1
	}
	exe, exe_err := os.get_executable_path(context.allocator)
	if exe_err != nil do return {}, "could not find zclaude's own path"
	// Hooks reach the session through a socket; without one they only observe nothing.
	hook_socket := app.socket_path
	if opts.no_socket {
		hook_socket = fmt.aprintf("%s/%d.hooks.sock", dir, pid)
		app.socket_path = hook_socket
		fd, ok := listen_unix(hook_socket)
		if !ok do return {}, "could not open the hook socket"
		app.listen_fd = fd
	}
	settings, serr := build_settings(exe, hook_socket, user_settings)
	if serr != "" do return {}, serr

	// Loads the agent inside Claude's process. `.cjs` so Node always treats it as
	// CommonJS. If a future Claude Code ignores the preload, the session still works
	// and `agent_connected` stays false.
	app.agent_path = fmt.aprintf("%s/%d.agent.cjs", dir, pid)
	if !write_private_file(app.agent_path, AGENT_JS) do return {}, "could not write the agent file"

	set := make([dynamic]string, context.temp_allocator)
	append(&set, fmt.tprintf("ZCLAUDE_AGENT_SOCKET=%s", app.socket_path))
	runtime := detect_runtime(claude)
	if runtime == .Bun || runtime == .Both {
		original := os.get_env("BUN_OPTIONS", context.temp_allocator)
		append(&set, strings.trim_left_space(fmt.tprintf("BUN_OPTIONS=%s --preload %s", original, app.agent_path)))
		append(&set, fmt.tprintf("ZCLAUDE_ORIGINAL_BUN_OPTIONS=%s", original))
	}
	if runtime == .Node || runtime == .Both {
		original := os.get_env("NODE_OPTIONS", context.temp_allocator)
		req := strings.contains_any(app.agent_path, " \t") ? fmt.tprintf("--require \"%s\"", app.agent_path) : fmt.tprintf("--require %s", app.agent_path)
		append(&set, fmt.tprintf("NODE_OPTIONS=%s", strings.trim_space(fmt.tprintf("%s %s", original, req))))
		append(&set, fmt.tprintf("ZCLAUDE_ORIGINAL_NODE_OPTIONS=%s", original))
	}
	if opts.code_mode do append(&set, "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1")
	if opts.stdio {
		append(&set, "TERM=xterm-256color")
		append(&set, "COLORTERM=truecolor")
	}
	p.env = build_env(set[:])

	// Ours comes first so that a variadic user flag can't swallow it.
	p.argv = make([dynamic]string)
	append(&p.argv, "--settings", settings)
	append(&p.argv, ..args[:])

	h := hub()
	if model := initial_model(args[:]); model != "" do h.model = strings.clone(model)
	if opts.code_mode || is_truthy_env("CLAUDE_CODE_EXPERIMENTAL_CODE_MODE") do h.code_mode = true
	return p, ""
}

cleanup_files :: proc() {
	if app.listen_fd >= 0 do c_unlink(strings.clone_to_cstring(app.socket_path, context.temp_allocator))
	if app.agent_path != "" do c_unlink(strings.clone_to_cstring(app.agent_path, context.temp_allocator))
}

run :: proc(raw_args: []string) -> int {
	opts, args, perr := parse_options(raw_args)
	if perr != "" do return fail("%s", perr)
	if opts.log != "" {
		app.log_fd = c_open(strings.clone_to_cstring(opts.log, context.temp_allocator), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
	}
	app.pty_fd = -1
	app.listen_fd = -1
	if !opts.stdio && (is_passthrough(args[:]) || c_isatty(0) == 0 || c_isatty(1) == 0) {
		claude, found := find_claude()
		if !found do return fail("`claude` was not found")
		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, claude)
		append(&argv, ..args[:])
		set := make([dynamic]string, context.temp_allocator)
		if opts.code_mode do append(&set, "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1")
		env, _ := os.environ(context.temp_allocator)
		if opts.code_mode do env = build_env(set[:])
		c_execve(strings.clone_to_cstring(claude, context.temp_allocator), cstrings(argv[:]), cstrings(env))
		return fail("could not run %s", claude)
	}
	hub_init()
	p, err := prepare(opts, args)
	if err != "" {
		cleanup_files()
		return fail("%s", err)
	}
	c_signal(SIGPIPE, SIG_IGN)
	if opts.stdio do return run_stdio(opts, p)
	return run_interactive(p)
}

// ---------- Headless ----------

run_stdio :: proc(opts: Options, p: Prepared) -> int {
	ws := Winsize{rows = u16(opts.rows), cols = u16(opts.cols)}
	app.mode = .Stdio
	app.screen = screen_make(opts.cols, opts.rows)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, p.claude)
	append(&argv, ..p.argv[:])
	master, pid, ok := spawn_pty(p.claude, argv[:], p.env, ws, nil)
	if !ok {
		cleanup_files()
		return fail("could not start %s under a PTY", p.claude)
	}
	app.pty_fd = master
	app.child_pid = pid
	set_nonblocking(0)
	set_nonblocking(1)
	cl := client_add(0, 1, is_stdio = true)
	cl.kind = .Control
	// The owner hears everything from the start; `subscribe` can add the terminal.
	cl.subscribed = true
	install_signal_pipe({SIGCHLD, SIGTERM, SIGHUP, SIGINT})
	ev := event("ready", only = cl)
	jw_raw(&ev.w, "snapshot", snapshot_json())
	event_send(ev)
	loop_run(Loop_Hooks{stdin_fd = -1, on_signal = stdio_signal})
	cleanup_files()
	return app.exit_code
}

stdio_signal :: proc(sig: int) {
	switch c.int(sig) {
	case SIGCHLD:
		reap_child(false)
	case SIGTERM, SIGHUP, SIGINT:
		if !app.child_exited do c_kill(app.child_pid, SIGHUP)
	}
}

reap_child :: proc(job_control: bool) {
	for {
		status: c.int
		r := c_waitpid(app.child_pid, &status, WNOHANG | WUNTRACED)
		if r <= 0 do return
		if w_status_stopped(status) {
			if job_control {
				interactive_suspend()
			} else {
				// Nobody to `fg` from in headless mode, so carry on at once.
				c_kill(app.child_pid, SIGCONT)
			}
			continue
		}
		code := 0
		if w_status_exited(status) do code = w_status_code(status)
		else if w_status_signaled(status) do code = 128 + w_status_signal(status)
		hub_on_child_exit(code)
		return
	}
}

// ---------- Interactive ----------

outer_termios: posix.termios
have_outer: bool

set_raw :: proc() {
	if !have_outer do return
	raw := outer_termios
	c_cfmakeraw(&raw)
	posix.tcsetattr(0, .TCSADRAIN, &raw)
}

restore_terminal :: proc() {
	if have_outer do posix.tcsetattr(0, .TCSADRAIN, &outer_termios)
}

run_interactive :: proc(p: Prepared) -> int {
	app.mode = .Interactive
	if posix.tcgetattr(0, &outer_termios) == .OK do have_outer = true
	ws, ok := get_winsize(0)
	if !ok do ws = Winsize{rows = 24, cols = 80}
	app.screen = screen_make(int(ws.cols), int(ws.rows))
	exe, _ := os.get_executable_path(context.temp_allocator)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, exe, "__session", p.claude)
	append(&argv, ..p.argv[:])
	master, pid, spawned := spawn_pty(exe, argv[:], p.env, ws, have_outer ? &outer_termios : nil)
	if !spawned {
		cleanup_files()
		return fail("could not start a PTY")
	}
	app.pty_fd = master
	app.child_pid = pid
	set_raw()
	install_signal_pipe({SIGCHLD, SIGWINCH, SIGTERM, SIGHUP})
	loop_run(Loop_Hooks{stdin_fd = 0, on_stdin = interactive_stdin, on_signal = interactive_signal})
	restore_terminal()
	cleanup_files()
	return app.exit_code
}

interactive_stdin :: proc(data: []byte) {
	if data == nil {
		// The terminal is gone, so end the child the way closing it would.
		if !app.child_exited do c_kill(app.child_pid, SIGHUP)
		return
	}
	hub_on_terminal_input(data)
	pty_write(data)
}

interactive_signal :: proc(sig: int) {
	switch c.int(sig) {
	case SIGCHLD:
		reap_child(true)
	case SIGWINCH:
		if ws, ok := get_winsize(0); ok {
			set_winsize(app.pty_fd, ws)
			screen_resize(app.screen, int(ws.cols), int(ws.rows))
			ev := event("term.resize")
			jw_int(&ev.w, "cols", i64(ws.cols))
			jw_int(&ev.w, "rows", i64(ws.rows))
			event_send(ev)
		}
	case SIGTERM, SIGHUP:
		if !app.child_exited do c_kill(app.child_pid, c.int(sig))
	}
}

// Claude suspended itself (Ctrl-Z): suspend too, so the shell's job control works
// as it would without zclaude.
interactive_suspend :: proc() {
	restore_terminal()
	c_raise(SIGSTOP)
	// Execution continues here after `fg`.
	set_raw()
	if ws, ok := get_winsize(0); ok {
		set_winsize(app.pty_fd, ws)
		screen_resize(app.screen, int(ws.cols), int(ws.rows))
	}
	c_kill(app.child_pid, SIGCONT)
}

// Runs on the inner PTY as session leader, with Claude as a foreground job in its own
// process group, the way a shell runs a command. Without this Claude's group would
// be orphaned, and the kernel discards the SIGTSTP behind Ctrl-Z for orphaned groups.
// When Claude stops, this process stops too, which the wrapper sees through waitpid.
session_child: c.int

run_session :: proc(args: []string) -> int {
	if len(args) == 0 do return 2
	c_signal(SIGTTOU, SIG_IGN)
	env, _ := os.environ(context.temp_allocator)
	cpath := strings.clone_to_cstring(args[0], context.temp_allocator)
	cargv := cstrings(args)
	cenv := cstrings(env)
	pid := c_fork()
	if pid < 0 do return 1
	if pid == 0 {
		c_setpgid(0, 0)
		c_tcsetpgrp(0, c_getpid())
		c_signal(SIGTTOU, SIG_DFL)
		c_execve(cpath, cargv, cenv)
		msg := fmt.tprintf("could not start %s\n", args[0])
		write_all(2, transmute([]u8)msg)
		c_exit(127)
	}
	session_child = pid
	forward :: proc "c" (sig: c.int) {
		c_kill(session_child, sig)
	}
	c_signal(SIGTERM, rawptr(forward))
	c_signal(SIGHUP, rawptr(forward))
	c_setpgid(pid, pid)
	c_tcsetpgrp(0, pid)
	for {
		status: c.int
		r := c_waitpid(pid, &status, WUNTRACED)
		if r < 0 {
			if errno() == EINTR do continue
			return 1
		}
		if w_status_exited(status) do return w_status_code(status)
		if w_status_signaled(status) do return 128 + w_status_signal(status)
		if w_status_stopped(status) {
			c_raise(SIGSTOP)
			c_tcsetpgrp(0, pid)
			c_kill(-pid, SIGCONT)
		}
	}
}
