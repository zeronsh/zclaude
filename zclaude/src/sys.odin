package zclaude

// Thin libc bindings with plain C types. core:sys/posix is typed with bit sets and
// enums, which makes fd plumbing noisy, so only termios comes from there.

import "core:c"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

@(default_calling_convention = "c")
foreign libc {
	@(link_name = "read")       c_read       :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	@(link_name = "write")      c_write      :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	@(link_name = "close")      c_close      :: proc(fd: c.int) -> c.int ---
	@(link_name = "fcntl")      c_fcntl      :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..c.int) -> c.int ---
	@(link_name = "ioctl")      c_ioctl      :: proc(fd: c.int, req: c.ulong, #c_vararg args: ..rawptr) -> c.int ---
	@(link_name = "pipe")       c_pipe       :: proc(fds: ^[2]c.int) -> c.int ---
	@(link_name = "dup2")       c_dup2       :: proc(a, b: c.int) -> c.int ---
	@(link_name = "fork")       c_fork       :: proc() -> c.int ---
	@(link_name = "execve")     c_execve     :: proc(path: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int ---
	@(link_name = "_exit")      c_exit       :: proc(code: c.int) -> ! ---
	@(link_name = "waitpid")    c_waitpid    :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
	@(link_name = "kill")       c_kill       :: proc(pid: c.int, sig: c.int) -> c.int ---
	@(link_name = "raise")      c_raise      :: proc(sig: c.int) -> c.int ---
	@(link_name = "getpid")     c_getpid     :: proc() -> c.int ---
	@(link_name = "setsid")     c_setsid     :: proc() -> c.int ---
	@(link_name = "setpgid")    c_setpgid    :: proc(pid, pgid: c.int) -> c.int ---
	@(link_name = "tcsetpgrp")  c_tcsetpgrp  :: proc(fd: c.int, pgrp: c.int) -> c.int ---
	@(link_name = "signal")     c_signal     :: proc(sig: c.int, handler: rawptr) -> rawptr ---
	@(link_name = "poll")       c_poll       :: proc(fds: [^]Poll_Fd, n: c.uint, timeout: c.int) -> c.int ---
	@(link_name = "socket")     c_socket     :: proc(domain, kind, protocol: c.int) -> c.int ---
	@(link_name = "bind")       c_bind       :: proc(fd: c.int, addr: rawptr, len: u32) -> c.int ---
	@(link_name = "listen")     c_listen     :: proc(fd: c.int, backlog: c.int) -> c.int ---
	@(link_name = "accept")     c_accept     :: proc(fd: c.int, addr: rawptr, len: ^u32) -> c.int ---
	@(link_name = "connect")    c_connect    :: proc(fd: c.int, addr: rawptr, len: u32) -> c.int ---
	@(link_name = "unlink")     c_unlink     :: proc(path: cstring) -> c.int ---
	@(link_name = "access")     c_access     :: proc(path: cstring, mode: c.int) -> c.int ---
	@(link_name = "isatty")     c_isatty     :: proc(fd: c.int) -> c.int ---
	@(link_name = "posix_openpt") c_posix_openpt :: proc(flags: c.int) -> c.int ---
	@(link_name = "grantpt")    c_grantpt    :: proc(fd: c.int) -> c.int ---
	@(link_name = "unlockpt")   c_unlockpt   :: proc(fd: c.int) -> c.int ---
	@(link_name = "ptsname")    c_ptsname    :: proc(fd: c.int) -> cstring ---
	@(link_name = "cfmakeraw")  c_cfmakeraw  :: proc(t: ^posix.termios) ---
	@(link_name = "realpath")   c_realpath   :: proc(path: cstring, resolved: [^]u8) -> cstring ---
	@(link_name = "lseek")      c_lseek      :: proc(fd: c.int, off: i64, whence: c.int) -> i64 ---
}

// open(2) and chmod(2) are declared by core:sys/posix with typed flags, and a
// foreign procedure may only be declared once, so these convert.
c_open :: proc(path: cstring, flags: c.int, mode: c.int = 0) -> c.int {
	return c.int(posix.open(path, transmute(posix.O_Flags)flags, transmute(posix.mode_t)posix._mode_t(mode)))
}

c_chmod :: proc(path: cstring, mode: c.int) -> c.int {
	return posix.chmod(path, transmute(posix.mode_t)posix._mode_t(mode)) == .OK ? 0 : -1
}

Poll_Fd :: struct {
	fd:      c.int,
	events:  c.short,
	revents: c.short,
}

POLLIN   :: 0x1
POLLOUT  :: 0x4
POLLERR  :: 0x8
POLLHUP  :: 0x10
POLLNVAL :: 0x20

F_SETFD    :: 2
F_GETFL    :: 3
F_SETFL    :: 4
FD_CLOEXEC :: 1

AF_UNIX     :: 1
SOCK_STREAM :: 1

WNOHANG   :: 1
WUNTRACED :: 2

SIGHUP  :: 1
SIGINT  :: 2
SIGKILL :: 9
SIGPIPE :: 13
SIGTERM :: 15
SIGWINCH :: 28

SIG_DFL :: rawptr(uintptr(0))
SIG_IGN :: rawptr(uintptr(1))

EINTR :: 4

when ODIN_OS == .Darwin {
	O_RDWR     :: 0x2
	O_NONBLOCK :: 0x4
	O_NOCTTY   :: 0x20000
	EAGAIN     :: 35
	EINPROGRESS :: 36
	SIGCHLD :: 20
	SIGCONT :: 19
	SIGSTOP :: 17
	SIGTSTP :: 18
	SIGTTIN :: 21
	SIGTTOU :: 22
	TIOCSWINSZ :: c.ulong(0x80087467)
	TIOCGWINSZ :: c.ulong(0x40087468)
	TIOCSCTTY  :: c.ulong(0x20007461)
	Sockaddr_Un :: struct {
		sun_len:    u8,
		sun_family: u8,
		sun_path:   [104]u8,
	}
} else {
	O_RDWR     :: 0x2
	O_NONBLOCK :: 0o4000
	O_NOCTTY   :: 0o400
	EAGAIN     :: 11
	EINPROGRESS :: 115
	SIGCHLD :: 17
	SIGCONT :: 18
	SIGSTOP :: 19
	SIGTSTP :: 20
	SIGTTIN :: 21
	SIGTTOU :: 22
	TIOCSWINSZ :: c.ulong(0x5414)
	TIOCGWINSZ :: c.ulong(0x5413)
	TIOCSCTTY  :: c.ulong(0x540E)
	Sockaddr_Un :: struct {
		sun_family: u16,
		sun_path:   [108]u8,
	}
}

Winsize :: struct {
	rows, cols, xpixel, ypixel: u16,
}

errno :: proc() -> int {
	return int(posix.errno())
}

set_nonblocking :: proc(fd: c.int) {
	flags := c_fcntl(fd, F_GETFL)
	c_fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

set_cloexec :: proc(fd: c.int) {
	c_fcntl(fd, F_SETFD, FD_CLOEXEC)
}

get_winsize :: proc(fd: c.int) -> (Winsize, bool) {
	ws: Winsize
	if c_ioctl(fd, TIOCGWINSZ, &ws) != 0 || ws.cols == 0 {
		return {}, false
	}
	return ws, true
}

set_winsize :: proc(fd: c.int, ws: Winsize) {
	w := ws
	c_ioctl(fd, TIOCSWINSZ, &w)
}

w_status_exited :: proc(s: c.int) -> bool {return s & 0x7f == 0}
w_status_code :: proc(s: c.int) -> int {return int((s >> 8) & 0xff)}
w_status_signaled :: proc(s: c.int) -> bool {return s & 0x7f != 0x7f && s & 0x7f != 0}
w_status_signal :: proc(s: c.int) -> int {return int(s & 0x7f)}
w_status_stopped :: proc(s: c.int) -> bool {return s & 0xff == 0x7f}

// Writes all of `data`, retrying on EINTR and waiting out EAGAIN. For blocking
// destinations like the real terminal and short-lived hook connections.
write_all :: proc(fd: c.int, data: []byte) -> bool {
	off := 0
	for off < len(data) {
		remaining := len(data) - off
		n := c_write(fd, raw_data(data[off:]), c.size_t(remaining))
		if n < 0 {
			e := errno()
			if e == EINTR do continue
			if e == EAGAIN {
				pfd := [1]Poll_Fd{{fd = fd, events = POLLOUT}}
				c_poll(&pfd[0], 1, 100)
				continue
			}
			return false
		}
		off += int(n)
	}
	return true
}

fill_sockaddr :: proc(path: string) -> (addr: Sockaddr_Un, ok: bool) {
	if len(path) >= len(addr.sun_path) do return {}, false
	when ODIN_OS == .Darwin {
		addr.sun_len = u8(size_of(Sockaddr_Un))
		addr.sun_family = AF_UNIX
	} else {
		addr.sun_family = AF_UNIX
	}
	copy(addr.sun_path[:], path)
	return addr, true
}

// Listens on a Unix socket readable and writable only by the owner.
listen_unix :: proc(path: string) -> (c.int, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	c_unlink(cpath)
	addr, ok := fill_sockaddr(path)
	if !ok do return -1, false
	fd := c_socket(AF_UNIX, SOCK_STREAM, 0)
	if fd < 0 do return -1, false
	if c_bind(fd, &addr, u32(size_of(addr))) != 0 {
		c_close(fd)
		return -1, false
	}
	c_chmod(cpath, 0o600)
	if c_listen(fd, 64) != 0 {
		c_close(fd)
		return -1, false
	}
	set_nonblocking(fd)
	set_cloexec(fd)
	return fd, true
}

connect_unix :: proc(path: string) -> (c.int, bool) {
	addr, ok := fill_sockaddr(path)
	if !ok do return -1, false
	fd := c_socket(AF_UNIX, SOCK_STREAM, 0)
	if fd < 0 do return -1, false
	if c_connect(fd, &addr, u32(size_of(addr))) != 0 {
		c_close(fd)
		return -1, false
	}
	set_cloexec(fd)
	return fd, true
}

// Signals become bytes on a pipe so the event loop can handle them in order.
signal_pipe: [2]c.int

@(private = "file")
on_signal :: proc "c" (sig: c.int) {
	b := u8(sig)
	c_write(signal_pipe[1], &b, 1)
}

install_signal_pipe :: proc(signals: []c.int) {
	c_pipe(&signal_pipe)
	set_nonblocking(signal_pipe[0])
	set_nonblocking(signal_pipe[1])
	set_cloexec(signal_pipe[0])
	set_cloexec(signal_pipe[1])
	for s in signals {
		c_signal(s, rawptr(on_signal))
	}
}

process_alive :: proc(pid: int) -> bool {
	if c_kill(c.int(pid), 0) == 0 do return true
	return errno() != 3 // ESRCH
}

realpath :: proc(path: string, allocator := context.allocator) -> string {
	buf: [4096]u8
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	res := c_realpath(cpath, &buf[0])
	if res == nil do return strings.clone(path, allocator)
	return strings.clone(string(res), allocator)
}
