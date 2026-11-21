package zclaude

// The event loop. One thread polls the PTY, the real terminal (interactive mode),
// stdin/stdout (stdio mode), the control socket and its clients, and a signal
// pipe. All session state lives on this thread, so nothing needs a lock.

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

PROTOCOL_VERSION :: 1
// A consumer this far behind is dropped rather than letting memory grow forever.
MAX_CLIENT_BACKLOG :: 64 * 1024 * 1024

Mode :: enum {
	Interactive,
	Stdio,
}

Client_Kind :: enum {
	Unknown,
	Control,
	Agent,
	Hook_Event,
	Hook_Permission,
	Hook_Elicitation,
	Hook_Wait,
}

Client :: struct {
	id:         int,
	in_fd:      c.int,
	out_fd:     c.int,
	kind:       Client_Kind,
	rbuf:       [dynamic]u8,
	wbuf:       [dynamic]u8,
	woff:       int,
	dead:       bool,
	is_stdio:   bool,
	subscribed: bool,
	sub_term:   bool,
	// A held request (hook.permission, hook.wait, ...) is answered with this id.
	held_id:    string,
}

Timer_Kind :: enum {
	Input,       // write `data` to Claude, through the agent or the PTY
	Enter,       // submit a typed prompt, unless a card has opened over it
	Enter_Retry, // resend Enter until UserPromptSubmit confirms a prompt
	Mode_Step,   // one step of cycling the permission mode with Shift+Tab
	Memory_Timeout,
	Settle,      // an answered card's wait for Claude Code to take it down ran out
	Shutdown,    // the next step of a graceful shutdown
}

Input_Route :: enum {
	Agent, // process.stdin.push inside Claude: what the TUI reads keys from
	Pty,   // the terminal itself, exactly like typing
}

Timer :: struct {
	at:     i64,
	kind:   Timer_Kind,
	route:  Input_Route,
	n:      int,
	gen:    int,
	data:   string,
}

App :: struct {
	mode:          Mode,
	socket_path:   string,
	agent_path:    string,
	listen_fd:     c.int,
	pty_fd:        c.int,
	child_pid:     c.int,
	child_exited:  bool,
	exit_code:     int,
	exit_signal:   int, // the signal that ended Claude, 0 if it exited by itself
	shutdown:      Shutdown,
	pty_wbuf:      [dynamic]u8,
	pty_woff:      int,
	clients:       [dynamic]^Client,
	next_client:   int,
	timers:        [dynamic]Timer,
	screen:        ^Screen,
	seq:           i64,
	last_poll:     i64,
	start_ms:      i64,
	utf8_carry:    [4]u8,
	utf8_carry_n:  int,
	hub:           Hub,
	log_fd:        c.int,
}

app: App

Shutdown_Stage :: enum {
	None,
	Graceful, // ending the turn and typing /exit
	Hangup,   // SIGHUP sent
	Killed,   // SIGKILL sent
}

Shutdown :: struct {
	stage:     Shutdown_Stage,
	hup_at:    i64, // when the graceful stage gives up
	kill_at:   i64,
	esc_at:    i64,
	exit_at:   i64, // when /exit was typed
	exits:     int,
}

now_ms :: proc() -> i64 {
	return time.tick_now()._nsec / 1_000_000
}

wall_ms :: proc() -> i64 {
	return time.now()._nsec / 1_000_000
}

debug_log :: proc(format: string, args: ..any) {
	if app.log_fd <= 0 do return
	s := fmt.tprintf(format, ..args)
	line := fmt.tprintf("%d %s\n", wall_ms(), s)
	write_all(app.log_fd, transmute([]u8)line)
}

// ---------- Clients ----------

client_add :: proc(in_fd, out_fd: c.int, is_stdio := false) -> ^Client {
	app.next_client += 1
	cl := new(Client)
	cl.id = app.next_client
	cl.in_fd = in_fd
	cl.out_fd = out_fd
	cl.is_stdio = is_stdio
	append(&app.clients, cl)
	return cl
}

client_by_id :: proc(id: int) -> ^Client {
	for cl in app.clients {
		if cl.id == id && !cl.dead do return cl
	}
	return nil
}

// Queues bytes for a client and writes as much as the socket takes now.
client_send :: proc(cl: ^Client, data: string) {
	if cl == nil || cl.dead do return
	append(&cl.wbuf, ..transmute([]u8)data)
	if len(cl.wbuf) - cl.woff > MAX_CLIENT_BACKLOG {
		debug_log("client %d fell too far behind, dropping", cl.id)
		client_close(cl)
		return
	}
	client_flush(cl)
}

client_flush :: proc(cl: ^Client) {
	for cl.woff < len(cl.wbuf) {
		remaining := len(cl.wbuf) - cl.woff
		n := c_write(cl.out_fd, raw_data(cl.wbuf[cl.woff:]), c.size_t(remaining))
		if n < 0 {
			e := errno()
			if e == EINTR do continue
			if e == EAGAIN do break
			client_close(cl)
			return
		}
		cl.woff += int(n)
	}
	if cl.woff == len(cl.wbuf) {
		clear(&cl.wbuf)
		cl.woff = 0
	} else if cl.woff > 1 << 20 {
		remove_range(&cl.wbuf, 0, cl.woff)
		cl.woff = 0
	}
}

client_close :: proc(cl: ^Client) {
	if cl.dead do return
	cl.dead = true
	hub_client_gone(cl)
	if !cl.is_stdio {
		c_close(cl.in_fd)
	}
}

client_free_dead :: proc() {
	i := 0
	for i < len(app.clients) {
		cl := app.clients[i]
		if cl.dead {
			delete(cl.rbuf)
			delete(cl.wbuf)
			delete(cl.held_id)
			free(cl)
			ordered_remove(&app.clients, i)
		} else {
			i += 1
		}
	}
}

reply_result :: proc(cl: ^Client, id: string, result: string) {
	if cl == nil || id == "" do return
	msg := fmt.tprintf("{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}}\n", id, len(result) > 0 ? result : "null")
	client_send(cl, msg)
}

reply_error :: proc(cl: ^Client, id: string, message: string, code := -32000) {
	if cl == nil do return
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"jsonrpc\":\"2.0\",\"id\":")
	strings.write_string(&b, len(id) > 0 ? id : "null")
	strings.write_string(&b, ",\"error\":{\"code\":")
	strings.write_int(&b, code)
	strings.write_string(&b, ",\"message\":")
	write_quoted(&b, message)
	strings.write_string(&b, "}}\n")
	client_send(cl, strings.to_string(b))
}

// ---------- Events ----------

Event :: struct {
	b: strings.Builder,
	w: Jw,
	term: bool,
	only: ^Client,
}

// Starts a notification. Fields go into `params`, which already holds `seq`.
event_begin :: proc(method: string, term := false, only: ^Client = nil) -> Event {
	ev: Event
	ev.b = strings.builder_make(context.temp_allocator)
	ev.term = term
	ev.only = only
	strings.write_string(&ev.b, "{\"jsonrpc\":\"2.0\",\"method\":\"")
	strings.write_string(&ev.b, method)
	strings.write_string(&ev.b, "\",\"params\":")
	app.seq += 1
	return ev
}

// Call after event_begin, through `ev := event(...)`, to get a writer with the
// params object open.
event :: proc(method: string, term := false, only: ^Client = nil) -> ^Event {
	ev := new(Event, context.temp_allocator)
	ev^ = event_begin(method, term, only)
	ev.w = jw_make(&ev.b)
	jw_obj(&ev.w)
	jw_int(&ev.w, "seq", app.seq)
	return ev
}

event_send :: proc(ev: ^Event) {
	jw_end_obj(&ev.w)
	strings.write_string(&ev.b, "}\n")
	line := strings.to_string(ev.b)
	if ev.only != nil {
		client_send(ev.only, line)
		return
	}
	for cl in app.clients {
		if cl.dead || !cl.subscribed do continue
		if ev.term && !cl.sub_term do continue
		client_send(cl, line)
	}
}

has_subscribers :: proc(term := false) -> bool {
	for cl in app.clients {
		if cl.dead || !cl.subscribed do continue
		if term && !cl.sub_term do continue
		return true
	}
	return false
}

// ---------- Timers ----------

timer_add :: proc(delay_ms: i64, kind: Timer_Kind, data := "", route := Input_Route.Pty, n := 0, gen := 0) {
	append(&app.timers, Timer{at = now_ms() + delay_ms, kind = kind, data = strings.clone(data), route = route, n = n, gen = gen})
}

next_timer_ms :: proc() -> i64 {
	best: i64 = -1
	for t in app.timers {
		if best < 0 || t.at < best do best = t.at
	}
	return best
}

run_due_timers :: proc() {
	now := now_ms()
	for {
		idx := -1
		for t, i in app.timers {
			if t.at <= now && (idx < 0 || t.at < app.timers[idx].at) do idx = i
		}
		if idx < 0 do return
		t := app.timers[idx]
		ordered_remove(&app.timers, idx)
		hub_on_timer(t)
		delete(t.data)
	}
}

// ---------- PTY ----------

pty_write :: proc(data: []byte) {
	if app.pty_fd < 0 do return
	append(&app.pty_wbuf, ..data)
	pty_flush()
}

pty_flush :: proc() {
	for app.pty_woff < len(app.pty_wbuf) {
		// Small writes: a TTY's input queue is limited, and a big burst can be dropped.
		chunk := min(len(app.pty_wbuf) - app.pty_woff, 512)
		n := c_write(app.pty_fd, raw_data(app.pty_wbuf[app.pty_woff:]), c.size_t(chunk))
		if n < 0 {
			e := errno()
			if e == EINTR do continue
			break
		}
		app.pty_woff += int(n)
	}
	if app.pty_woff == len(app.pty_wbuf) {
		clear(&app.pty_wbuf)
		app.pty_woff = 0
	}
}

on_pty_output :: proc(data: []byte) {
	if app.mode == .Interactive {
		// The real terminal: a blocking write, as a terminal drains quickly.
		write_all(1, data)
	}
	screen_feed(app.screen, data)
	hub_on_screen_change()
	if has_subscribers(term = true) {
		ev := event("term.output", term = true)
		jw_str(&ev.w, "data", base64.encode(data, allocator = context.temp_allocator))
		event_send(ev)
	}
}

// ---------- Loop ----------

Loop_Hooks :: struct {
	on_stdin:   proc(data: []byte), // interactive: keys from the real terminal
	on_signal:  proc(sig: int),
	stdin_fd:   c.int,
}

loop_run :: proc(hooks: Loop_Hooks) {
	fds := make([dynamic]Poll_Fd)
	owners := make([dynamic]int) // -1 listen, -2 pty, -3 signals, -4 stdin, else client index
	rbuf := make([]u8, 65536)
	stdin_open := hooks.stdin_fd >= 0
	pty_open := true
	exit_deadline: i64 = -1

	for {
		clear(&fds)
		clear(&owners)
		if app.listen_fd >= 0 {
			append(&fds, Poll_Fd{fd = app.listen_fd, events = POLLIN})
			append(&owners, -1)
		}
		if pty_open {
			ev: c.short = POLLIN
			if app.pty_woff < len(app.pty_wbuf) do ev |= POLLOUT
			append(&fds, Poll_Fd{fd = app.pty_fd, events = ev})
			append(&owners, -2)
		}
		append(&fds, Poll_Fd{fd = signal_pipe[0], events = POLLIN})
		append(&owners, -3)
		if stdin_open {
			append(&fds, Poll_Fd{fd = hooks.stdin_fd, events = POLLIN})
			append(&owners, -4)
		}
		for cl, i in app.clients {
			if cl.dead do continue
			ev: c.short = 0
			if !(cl.is_stdio && app.mode == .Stdio && cl.in_fd < 0) do ev |= POLLIN
			if cl.woff < len(cl.wbuf) {
				if cl.out_fd == cl.in_fd {
					ev |= POLLOUT
				} else {
					append(&fds, Poll_Fd{fd = cl.out_fd, events = POLLOUT})
					append(&owners, 1_000_000 + i)
				}
			}
			if cl.in_fd >= 0 {
				append(&fds, Poll_Fd{fd = cl.in_fd, events = ev})
				append(&owners, i)
			}
		}

		timeout := max(app.last_poll + transcript_interval() - now_ms(), 0)
		// A changed screen is read again shortly (mode, plan choices), even if idle.
		if app.hub.screen_dirty do timeout = min(timeout, max(app.hub.screen_checked_at + SCREEN_CHECK_MS - now_ms(), 0))
		if nt := next_timer_ms(); nt >= 0 do timeout = min(timeout, max(nt - now_ms(), 0))
		if exit_deadline >= 0 do timeout = min(timeout, max(exit_deadline - now_ms(), 0))
		n := c_poll(raw_data(fds), c.uint(len(fds)), c.int(timeout))
		if n < 0 && errno() != EINTR {
			debug_log("poll failed: %d", errno())
		}

		if n > 0 {
			for pfd, k in fds {
				if pfd.revents == 0 do continue
				owner := owners[k]
				switch {
				case owner == -1:
					for {
						fd := c_accept(app.listen_fd, nil, nil)
						if fd < 0 do break
						set_nonblocking(fd)
						set_cloexec(fd)
						client_add(fd, fd)
					}
				case owner == -2:
					if pfd.revents & POLLOUT != 0 do pty_flush()
					if pfd.revents & (POLLIN | POLLHUP | POLLERR) != 0 {
						got := c_read(app.pty_fd, raw_data(rbuf), c.size_t(len(rbuf)))
						if got > 0 {
							on_pty_output(rbuf[:got])
						} else if got == 0 || (errno() != EAGAIN && errno() != EINTR) {
							// Linux reports EIO once the last slave fd closes.
							pty_open = false
						}
					}
				case owner == -3:
					sigs: [64]u8
					got := c_read(signal_pipe[0], &sigs[0], len(sigs))
					for s in 0 ..< max(int(got), 0) {
						if hooks.on_signal != nil do hooks.on_signal(int(sigs[s]))
					}
				case owner == -4:
					got := c_read(hooks.stdin_fd, raw_data(rbuf), c.size_t(len(rbuf)))
					if got > 0 {
						if hooks.on_stdin != nil do hooks.on_stdin(rbuf[:got])
					} else if got == 0 || (errno() != EAGAIN && errno() != EINTR) {
						stdin_open = false
						if hooks.on_stdin != nil do hooks.on_stdin(nil)
					}
				case owner >= 1_000_000:
					cl := app.clients[owner - 1_000_000]
					if !cl.dead do client_flush(cl)
				case:
					cl := app.clients[owner]
					if cl.dead do continue
					if pfd.revents & POLLOUT != 0 do client_flush(cl)
					if cl.dead do continue
					if pfd.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
						got := c_read(cl.in_fd, raw_data(rbuf), c.size_t(len(rbuf)))
						if got > 0 {
							append(&cl.rbuf, ..rbuf[:got])
							client_process_lines(cl)
						} else if got == 0 || (errno() != EAGAIN && errno() != EINTR) {
							if cl.is_stdio {
								// The consumer that owns this session has gone.
								cl.in_fd = -1
								hub_stdio_closed()
							}
							client_close(cl)
						}
					}
				}
			}
		}

		run_due_timers()
		if now_ms() - app.last_poll >= transcript_interval() {
			app.last_poll = now_ms()
			hub_poll_transcript()
		}
		hub_after_tick()
		client_free_dead()

		if app.child_exited && exit_deadline < 0 {
			// Drain the last output and let consumers read the final events.
			exit_deadline = now_ms() + 150
		}
		if app.child_exited && !pty_open && exit_deadline >= 0 && now_ms() >= exit_deadline {
			break
		}
		if app.child_exited && exit_deadline >= 0 && now_ms() >= exit_deadline + 500 {
			break
		}
		free_all(context.temp_allocator)
	}
	hub_on_exit()
	// Flush what consumers are owed, briefly.
	deadline := now_ms() + 300
	for now_ms() < deadline {
		pending := false
		for cl in app.clients {
			if !cl.dead && cl.woff < len(cl.wbuf) {
				client_flush(cl)
				if cl.woff < len(cl.wbuf) do pending = true
			}
		}
		if !pending do break
		pfd := Poll_Fd{fd = -1}
		c_poll(&pfd, 0, 10)
	}
	delete(fds)
	delete(owners)
	delete(rbuf)
}

client_process_lines :: proc(cl: ^Client) {
	start := 0
	for i in 0 ..< len(cl.rbuf) {
		if cl.rbuf[i] != '\n' do continue
		line := string(cl.rbuf[start:i])
		start = i + 1
		if len(strings.trim_space(line)) == 0 do continue
		handle_message(cl, line)
		if cl.dead do return
	}
	if start > 0 do remove_range(&cl.rbuf, 0, start)
	if len(cl.rbuf) > 256 * 1024 * 1024 {
		reply_error(cl, "", "request too large")
		client_close(cl)
	}
}

_ :: os
