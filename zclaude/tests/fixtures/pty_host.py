#!/usr/bin/env python3
"""Runs a command on a new pseudo-terminal and relays it to plain pipes.

    python3 pty_host.py COMMAND [ARGS...]

What a terminal emulator does, minus the drawing: bytes on this process's stdin are
typed into the terminal, and the terminal's output is copied to stdout. Tests use it
to drive interactive programs from a pipe, where `script(1)` fails because it puts
its own stdin into raw mode. The size comes from PTY_COLS and PTY_ROWS (default
120x40). Exits with the command's status, or 128 + n when signal n ended it.
"""
import errno
import fcntl
import os
import select
import struct
import sys
import termios


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cols = int(os.environ.get("PTY_COLS", "120"))
    rows = int(os.environ.get("PTY_ROWS", "40"))
    master, slave = os.openpty()
    # Sized before the program starts, so it never sees a 0x0 terminal.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        try:
            os.execvp(sys.argv[1], sys.argv[1:])
        finally:
            os._exit(127)
    os.close(slave)

    stdin_open = True
    while True:
        watch = [master] + ([0] if stdin_open else [])
        try:
            ready, _, _ = select.select(watch, [], [])
        except InterruptedError:
            continue
        if 0 in ready:
            data = os.read(0, 65536)
            if data:
                os.write(master, data)
            else:
                # Closing the terminal would hang the program up; just stop typing.
                stdin_open = False
        if master in ready:
            try:
                data = os.read(master, 65536)
            except OSError as e:
                if e.errno != errno.EIO:  # Linux: the last slave fd closed
                    raise
                data = b""
            if not data:
                break
            out = memoryview(data)
            while out:
                out = out[os.write(1, out):]

    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main())
