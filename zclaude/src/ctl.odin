package zclaude

// `zclaude ctl`: drives a running session from another terminal or a script.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

CTL_USAGE :: `usage: zclaude ctl [--socket PATH] <command>

  list                          live sessions
  status                        state of the session
  send [--hook] [--image PATH]... TEXT
                                send a prompt (in-process by default, or the rewake hook)
  command /NAME [ARGS]          run a slash command, e.g. /compact
  model [NAME]                  show or switch the model
  effort LEVEL                  low | medium | high | xhigh | max (also saved as the default)
  mode NAME                     default | acceptEdits | plan | auto | dontAsk | bypassPermissions
  interrupt                     end the turn, or refuse the open dialog
  answer DIALOG_ID JSON         e.g. '{"answers":[{"selected":["Green"]}]}', '{"decision":"allow"}',
                                '{"decision":"approve","mode":"acceptEdits"}' or '{"option":2}'
  keys KEY...                   enter, esc, shift+tab, up, ctrl+c, ... or text:WORDS
  screen                        the terminal screen as text
  subscribe [--term] [--history]  print events as JSON lines
  memory                        heap statistics, read inside Claude's process
  tasks                         background tasks, as JSON
  stop-task ID                  stop a background task
  shutdown [--force]            end the session (/exit, then SIGHUP, then SIGKILL)
  call METHOD [JSON]            any method

Without --socket, the most recently started live session is used.`

Ctl :: struct {
	fd:      i32,
	next_id: int,
	pending: [dynamic]u8,
}

ctl_read_line :: proc(c: ^Ctl) -> (string, bool) {
	buf: [65536]u8
	for {
		if i, found := slice.linear_search(c.pending[:], '\n'); found {
			line := strings.clone(string(c.pending[:i]), context.temp_allocator)
			remove_range(&c.pending, 0, i + 1)
			return line, true
		}
		n := c_read(c.fd, &buf[0], len(buf))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do return "", false
		append(&c.pending, ..buf[:n])
	}
}

ctl_call :: proc(c: ^Ctl, method: string, params: string) -> (Value, string) {
	c.next_id += 1
	req := fmt.tprintf("{{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":\"%s\",\"params\":%s}}\n", c.next_id, method, params == "" ? "{}" : params)
	if !write_all(c.fd, transmute([]u8)req) do return nil, "could not write to the session"
	for {
		line, ok := ctl_read_line(c)
		if !ok do return nil, "the session closed the connection"
		v, parsed := parse_json(line)
		if !parsed do continue
		id, has := jint(v, "id")
		if !has || int(id) != c.next_id do continue
		if msg := jstr(v, "error", "message"); msg != "" do return nil, msg
		return jget(v, "result"), ""
	}
}

live_sockets :: proc() -> []string {
	dir := run_dir()
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return nil
	Found :: struct {
		path: string,
		time: i64,
	}
	found := make([dynamic]Found, context.temp_allocator)
	for f in files {
		if !strings.has_suffix(f.name, ".sock") do continue
		fd, ok := connect_unix(f.fullpath)
		if !ok {
			c_unlink(strings.clone_to_cstring(f.fullpath, context.temp_allocator))
			continue
		}
		c_close(fd)
		append(&found, Found{f.fullpath, f.modification_time._nsec})
	}
	slice.sort_by(found[:], proc(a, b: Found) -> bool {return a.time > b.time})
	out := make([]string, len(found), context.temp_allocator)
	for f, i in found do out[i] = f.path
	return out
}

json_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_quoted(&b, s)
	return strings.to_string(b)
}

run_ctl :: proc(args_in: []string) -> int {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, ..args_in)
	socket := ""
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--socket" && i + 1 < len(args) {
			socket = args[i + 1]
			remove_range(&args, i, i + 2)
			break
		}
	}
	if len(args) == 0 {
		fmt.eprintln(CTL_USAGE)
		return 2
	}
	command := args[0]
	rest := args[1:]
	if command == "list" {
		for path in live_sockets() {
			fd, ok := connect_unix(path)
			if !ok do continue
			c := Ctl{fd = fd}
			v, err := ctl_call(&c, "status", "")
			c_close(fd)
			if err == "" do fmt.printfln("%s\t%s\t%s", path, jstr(v, "state"), jstr(v, "meta", "session_id"))
		}
		return 0
	}
	if socket == "" {
		sockets := live_sockets()
		if len(sockets) == 0 {
			fmt.eprintln("zclaude: no session is running")
			return 1
		}
		socket = sockets[0]
	}
	fd, ok := connect_unix(socket)
	if !ok {
		fmt.eprintfln("zclaude: could not connect to %s", socket)
		return 1
	}
	c := Ctl{fd = fd}
	method, params: string
	switch command {
	case "status":
		method = "status"
	case "send":
		transport := "inproc"
		words := make([dynamic]string, context.temp_allocator)
		images := strings.builder_make(context.temp_allocator)
		for i := 0; i < len(rest); i += 1 {
			a := rest[i]
			if a == "--hook" {
				transport = "hook"
			} else if a == "--image" && i + 1 < len(rest) {
				i += 1
				if strings.builder_len(images) > 0 do strings.write_byte(&images, ',')
				strings.write_string(&images, fmt.tprintf("{{\"path\":%s}}", json_string(realpath(rest[i], context.temp_allocator))))
			} else {
				append(&words, a)
			}
		}
		method = "prompt.send"
		params = fmt.tprintf("{{\"text\":%s,\"transport\":\"%s\",\"images\":[%s]}}", json_string(strings.join(words[:], " ", context.temp_allocator)), transport, strings.to_string(images))
	case "command":
		method = "command"
		params = fmt.tprintf("{{\"text\":%s}}", json_string(strings.join(rest, " ", context.temp_allocator)))
	case "model":
		if len(rest) == 0 {
			v, err := ctl_call(&c, "status", "")
			if err != "" do return ctl_fail(err)
			fmt.println(to_json(jget(v, "meta"), context.temp_allocator))
			return 0
		}
		method = "model.set"
		params = fmt.tprintf("{{\"model\":%s}}", json_string(rest[0]))
	case "mode":
		if len(rest) != 1 do return ctl_usage()
		method = "mode.set"
		params = fmt.tprintf("{{\"mode\":%s}}", json_string(rest[0]))
	case "interrupt":
		method = "interrupt"
	case "answer":
		if len(rest) != 2 do return ctl_usage()
		v, parsed := parse_json(rest[1])
		obj, is_obj := v.(Object)
		if !parsed || !is_obj do return ctl_fail("the answer must be a JSON object")
		obj["id"] = Value(json.String(rest[0]))
		method = "dialog.respond"
		params = to_json(obj, context.temp_allocator)
	case "keys":
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "{\"keys\":[")
		for k, i in rest {
			if i > 0 do strings.write_byte(&b, ',')
			if strings.has_prefix(k, "text:") {
				strings.write_string(&b, "{\"text\":")
				write_quoted(&b, k[5:])
				strings.write_string(&b, "}")
			} else {
				write_quoted(&b, k)
			}
		}
		strings.write_string(&b, "]}")
		method = "keys"
		params = strings.to_string(b)
	case "screen":
		v, err := ctl_call(&c, "screen", "")
		if err != "" do return ctl_fail(err)
		for line in jarr(v, "lines") do fmt.println(string(line.(json.String) or_else ""))
		return 0
	case "effort":
		if len(rest) != 1 do return ctl_usage()
		method = "effort.set"
		params = fmt.tprintf("{{\"level\":%s}}", json_string(rest[0]))
	case "tasks":
		v, err := ctl_call(&c, "status", "")
		if err != "" do return ctl_fail(err)
		fmt.println(to_json(jget(v, "tasks"), context.temp_allocator))
		return 0
	case "stop-task":
		if len(rest) != 1 do return ctl_usage()
		method = "task.stop"
		params = fmt.tprintf("{{\"id\":%s}}", json_string(rest[0]))
	case "memory":
		method = "memory"
	case "shutdown":
		method = "shutdown"
		params = fmt.tprintf("{{\"force\":%v}}", len(rest) > 0 && rest[0] == "--force")
	case "call":
		if len(rest) < 1 do return ctl_usage()
		method = rest[0]
		params = len(rest) > 1 ? rest[1] : "{}"
	case "subscribe":
		term, history := false, false
		for a in rest {
			if a == "--term" do term = true
			if a == "--history" do history = true
		}
		_, err := ctl_call(&c, "subscribe", fmt.tprintf("{{\"term\":%v,\"history\":%v}}", term, history))
		if err != "" do return ctl_fail(err)
		for {
			line, more := ctl_read_line(&c)
			if !more do return 0
			fmt.println(line)
			free_all(context.temp_allocator)
		}
	case:
		return ctl_usage()
	}
	v, err := ctl_call(&c, method, params)
	if err != "" do return ctl_fail(err)
	fmt.println(to_json(v, context.temp_allocator))
	return 0
}

ctl_usage :: proc() -> int {
	fmt.eprintln(CTL_USAGE)
	return 2
}

ctl_fail :: proc(err: string) -> int {
	fmt.eprintfln("zclaude: %s", err)
	return 1
}

import "core:encoding/json"
