package zclaude

// A small VT/xterm screen model fed with everything Claude writes to its terminal.
// It lets a consumer read the screen as text (to see any dialog, footer or menu
// exactly as a person would) and lets a terminal that attaches late be redrawn.
// It covers what Ink-based TUIs use: cursor movement, erase, scroll regions,
// insert/delete, SGR colors, the alternate screen and deferred wrap.

import "core:strings"

Attr :: struct {
	fg, bg: u32, // 0 default, 1<<24|index for palette, 2<<24|rgb
	flags:  u8,
}

ATTR_BOLD      :: 1
ATTR_DIM       :: 2
ATTR_ITALIC    :: 4
ATTR_UNDERLINE :: 8
ATTR_INVERSE   :: 16
ATTR_STRIKE    :: 32
ATTR_HIDDEN    :: 64

Cell :: struct {
	ch:    rune, // 0 for the right half of a wide character
	attr:  Attr,
}

Parse_State :: enum u8 {
	Ground,
	Esc,
	Csi,
	Osc,
	Str, // DCS, APC, PM, SOS: ignored until ST
	Charset,
}

Screen :: struct {
	cols, rows:      int,
	main, alt:       []Cell,
	using_alt:       bool,
	cx, cy:          int,
	pending_wrap:    bool,
	saved_cx, saved_cy: int,
	saved_attr:      Attr,
	attr:            Attr,
	top, bottom:     int,
	cursor_visible:  bool,
	bracketed_paste: bool,
	app_cursor:      bool,
	autowrap:        bool,
	// parser
	state:           Parse_State,
	params:          [16]int,
	nparams:         int,
	param_set:       bool,
	private:         u8,
	inter:           u8,
	str_esc:         bool,
	utf8:            [4]u8,
	utf8_len:        int,
}

screen_make :: proc(cols, rows: int) -> ^Screen {
	s := new(Screen)
	s.cols = max(cols, 2)
	s.rows = max(rows, 2)
	s.main = make([]Cell, s.cols * s.rows)
	s.alt = make([]Cell, s.cols * s.rows)
	blank_all(s.main)
	blank_all(s.alt)
	s.top = 0
	s.bottom = s.rows - 1
	s.cursor_visible = true
	s.autowrap = true
	return s
}

screen_destroy :: proc(s: ^Screen) {
	delete(s.main)
	delete(s.alt)
	free(s)
}

@(private = "file")
blank_all :: proc(cells: []Cell) {
	for &c in cells do c = Cell{ch = ' '}
}

buf :: proc(s: ^Screen) -> []Cell {
	return s.using_alt ? s.alt : s.main
}

@(private = "file")
blank :: proc(s: ^Screen) -> Cell {
	return Cell{ch = ' ', attr = Attr{bg = s.attr.bg}}
}

screen_resize :: proc(s: ^Screen, want_cols, want_rows: int) {
	cols, rows := max(want_cols, 2), max(want_rows, 2)
	if cols == s.cols && rows == s.rows do return
	resize_buf :: proc(old: []Cell, oc, or, nc, nr: int) -> []Cell {
		out := make([]Cell, nc * nr)
		for &c in out do c = Cell{ch = ' '}
		// Keep the bottom of the old screen, where the live UI is drawn.
		shift := max(or - nr, 0)
		for y in 0 ..< min(or, nr) {
			for x in 0 ..< min(oc, nc) {
				out[y * nc + x] = old[(y + shift) * oc + x]
			}
		}
		delete(old)
		return out
	}
	shift := max(s.rows - rows, 0)
	s.main = resize_buf(s.main, s.cols, s.rows, cols, rows)
	s.alt = resize_buf(s.alt, s.cols, s.rows, cols, rows)
	s.cols, s.rows = cols, rows
	s.cy = clamp(s.cy - shift, 0, rows - 1)
	s.cx = clamp(s.cx, 0, cols - 1)
	s.top, s.bottom = 0, rows - 1
	s.pending_wrap = false
}

screen_feed :: proc(s: ^Screen, data: []byte) {
	for b in data do feed_byte(s, b)
}

@(private = "file")
feed_byte :: proc(s: ^Screen, b: u8) {
	switch s.state {
	case .Ground:
		if s.utf8_len > 0 {
			if b & 0xC0 == 0x80 {
				s.utf8[s.utf8_len] = b
				s.utf8_len += 1
				need := utf8_need(s.utf8[0])
				if s.utf8_len >= need {
					r, _ := utf8_decode(string(s.utf8[:s.utf8_len]))
					s.utf8_len = 0
					print_rune(s, r)
				}
				return
			}
			s.utf8_len = 0
			print_rune(s, 0xFFFD)
		}
		switch {
		case b == 0x1b:
			s.state = .Esc
		case b < 0x20 || b == 0x7f:
			control(s, b)
		case b < 0x80:
			print_rune(s, rune(b))
		case:
			if utf8_need(b) > 1 {
				s.utf8[0] = b
				s.utf8_len = 1
			} else {
				print_rune(s, 0xFFFD)
			}
		}
	case .Esc:
		s.state = .Ground
		switch b {
		case '[':
			s.state = .Csi
			s.nparams = 0
			s.param_set = false
			s.private = 0
			s.inter = 0
			s.params = {}
		case ']':
			s.state = .Osc
			s.str_esc = false
		case 'P', '_', '^', 'X':
			s.state = .Str
			s.str_esc = false
		case '(', ')', '*', '+', '#', '%':
			s.state = .Charset
		case '7':
			save_cursor(s)
		case '8':
			restore_cursor(s)
		case 'M':
			reverse_index(s)
		case 'D':
			linefeed(s)
		case 'E':
			s.cx = 0
			linefeed(s)
		case 'c':
			reset(s)
		case 0x1b:
			s.state = .Esc
		}
	case .Charset:
		s.state = .Ground
	case .Osc, .Str:
		if s.str_esc {
			s.str_esc = false
			if b == '\\' {
				s.state = .Ground
				return
			}
		}
		if b == 0x07 && s.state == .Osc {
			s.state = .Ground
		} else if b == 0x1b {
			s.str_esc = true
		}
	case .Csi:
		switch {
		case b >= '0' && b <= '9':
			if s.nparams == 0 {
				s.nparams = 1
			}
			i := s.nparams - 1
			if i < len(s.params) {
				s.params[i] = min(s.params[i] * 10 + int(b - '0'), 65535)
			}
			s.param_set = true
		case b == ';' || b == ':':
			if s.nparams == 0 do s.nparams = 1
			if s.nparams < len(s.params) do s.nparams += 1
		case b >= '<' && b <= '?':
			s.private = b
		case b >= 0x20 && b <= 0x2f:
			s.inter = b
		case b >= 0x40 && b <= 0x7e:
			s.state = .Ground
			csi(s, b)
		case b == 0x1b:
			s.state = .Esc
		case b < 0x20:
			control(s, b)
		case:
			s.state = .Ground
		}
	}
}

@(private = "file")
utf8_need :: proc(b: u8) -> int {
	switch {
	case b & 0xE0 == 0xC0: return 2
	case b & 0xF0 == 0xE0: return 3
	case b & 0xF8 == 0xF0: return 4
	}
	return 1
}

rune_width :: proc(r: rune) -> int {
	switch r {
	case 0x0300 ..= 0x036F, 0x200B ..= 0x200F, 0x20D0 ..= 0x20FF, 0xFE00 ..= 0xFE0F, 0xE0100 ..= 0xE01EF:
		return 0
	case 0x1100 ..= 0x115F, 0x2E80 ..= 0x303E, 0x3041 ..= 0x33FF, 0x3400 ..= 0x4DBF, 0x4E00 ..= 0x9FFF,
	     0xA000 ..= 0xA4CF, 0xAC00 ..= 0xD7A3, 0xF900 ..= 0xFAFF, 0xFE30 ..= 0xFE4F, 0xFF00 ..= 0xFF60,
	     0xFFE0 ..= 0xFFE6, 0x1F300 ..= 0x1F64F, 0x1F680 ..= 0x1F6FF, 0x1F900 ..= 0x1F9FF, 0x20000 ..= 0x3FFFD:
		return 2
	}
	return 1
}

@(private = "file")
print_rune :: proc(s: ^Screen, r: rune) {
	w := rune_width(r)
	if w == 0 do return
	cells := buf(s)
	if s.pending_wrap {
		if s.autowrap {
			s.cx = 0
			linefeed(s)
		}
		s.pending_wrap = false
	}
	if w == 2 && s.cx >= s.cols - 1 {
		if !s.autowrap do return
		cells[s.cy * s.cols + s.cx] = blank(s)
		s.cx = 0
		linefeed(s)
	}
	cells[s.cy * s.cols + s.cx] = Cell{ch = r, attr = s.attr}
	if w == 2 {
		cells[s.cy * s.cols + s.cx + 1] = Cell{ch = 0, attr = s.attr}
	}
	s.cx += w
	if s.cx >= s.cols {
		s.cx = s.cols - 1
		s.pending_wrap = true
	}
}

@(private = "file")
control :: proc(s: ^Screen, b: u8) {
	switch b {
	case '\r':
		s.cx = 0
		s.pending_wrap = false
	case '\n', 0x0b, 0x0c:
		linefeed(s)
		s.pending_wrap = false
	case 0x08:
		if s.cx > 0 do s.cx -= 1
		s.pending_wrap = false
	case '\t':
		s.cx = min((s.cx / 8 + 1) * 8, s.cols - 1)
		s.pending_wrap = false
	}
}

@(private = "file")
linefeed :: proc(s: ^Screen) {
	if s.cy == s.bottom {
		scroll_up(s, s.top, s.bottom, 1)
	} else if s.cy < s.rows - 1 {
		s.cy += 1
	}
}

@(private = "file")
reverse_index :: proc(s: ^Screen) {
	if s.cy == s.top {
		scroll_down(s, s.top, s.bottom, 1)
	} else if s.cy > 0 {
		s.cy -= 1
	}
}

@(private = "file")
scroll_up :: proc(s: ^Screen, top, bottom, count: int) {
	cells := buf(s)
	n := min(count, bottom - top + 1)
	for y in top ..= bottom - n {
		copy(cells[y * s.cols:(y + 1) * s.cols], cells[(y + n) * s.cols:(y + n + 1) * s.cols])
	}
	for y in bottom - n + 1 ..= bottom {
		for x in 0 ..< s.cols do cells[y * s.cols + x] = blank(s)
	}
}

@(private = "file")
scroll_down :: proc(s: ^Screen, top, bottom, count: int) {
	cells := buf(s)
	n := min(count, bottom - top + 1)
	for y := bottom; y >= top + n; y -= 1 {
		copy(cells[y * s.cols:(y + 1) * s.cols], cells[(y - n) * s.cols:(y - n + 1) * s.cols])
	}
	for y in top ..< top + n {
		for x in 0 ..< s.cols do cells[y * s.cols + x] = blank(s)
	}
}

@(private = "file")
erase :: proc(s: ^Screen, from, to: int) {
	cells := buf(s)
	for i in max(from, 0) ..< min(to, len(cells)) do cells[i] = blank(s)
}

@(private = "file")
save_cursor :: proc(s: ^Screen) {
	s.saved_cx, s.saved_cy, s.saved_attr = s.cx, s.cy, s.attr
}

@(private = "file")
restore_cursor :: proc(s: ^Screen) {
	s.cx = clamp(s.saved_cx, 0, s.cols - 1)
	s.cy = clamp(s.saved_cy, 0, s.rows - 1)
	s.attr = s.saved_attr
	s.pending_wrap = false
}

@(private = "file")
reset :: proc(s: ^Screen) {
	blank_all(s.main)
	blank_all(s.alt)
	s.using_alt = false
	s.cx, s.cy = 0, 0
	s.attr = {}
	s.top, s.bottom = 0, s.rows - 1
	s.cursor_visible = true
	s.autowrap = true
	s.pending_wrap = false
}

@(private = "file")
param :: proc(s: ^Screen, i: int, default: int) -> int {
	if i >= s.nparams do return default
	v := s.params[i]
	return v == 0 ? default : v
}

@(private = "file")
csi :: proc(s: ^Screen, final: u8) {
	if s.inter != 0 do return // DECSCUSR and friends: no effect on content
	n := param(s, 0, 1)
	switch final {
	case 'A':
		s.cy = max(s.cy - n, s.cy >= s.top ? s.top : 0)
		s.pending_wrap = false
	case 'B', 'e':
		s.cy = min(s.cy + n, s.cy <= s.bottom ? s.bottom : s.rows - 1)
		s.pending_wrap = false
	case 'C', 'a':
		s.cx = min(s.cx + n, s.cols - 1)
		s.pending_wrap = false
	case 'D':
		s.cx = max(s.cx - n, 0)
		s.pending_wrap = false
	case 'E':
		s.cy = min(s.cy + n, s.rows - 1)
		s.cx = 0
		s.pending_wrap = false
	case 'F':
		s.cy = max(s.cy - n, 0)
		s.cx = 0
		s.pending_wrap = false
	case 'G', '`':
		s.cx = clamp(n - 1, 0, s.cols - 1)
		s.pending_wrap = false
	case 'd':
		s.cy = clamp(n - 1, 0, s.rows - 1)
		s.pending_wrap = false
	case 'H', 'f':
		s.cy = clamp(param(s, 0, 1) - 1, 0, s.rows - 1)
		s.cx = clamp(param(s, 1, 1) - 1, 0, s.cols - 1)
		s.pending_wrap = false
	case 'J':
		at := s.cy * s.cols + s.cx
		switch s.nparams > 0 ? s.params[0] : 0 {
		case 0: erase(s, at, s.cols * s.rows)
		case 1: erase(s, 0, at + 1)
		case 2, 3: erase(s, 0, s.cols * s.rows)
		}
	case 'K':
		row := s.cy * s.cols
		switch s.nparams > 0 ? s.params[0] : 0 {
		case 0: erase(s, row + s.cx, row + s.cols)
		case 1: erase(s, row, row + s.cx + 1)
		case 2: erase(s, row, row + s.cols)
		}
	case 'X':
		row := s.cy * s.cols
		erase(s, row + s.cx, row + min(s.cx + n, s.cols))
	case '@':
		cells := buf(s)
		row := s.cy * s.cols
		k := min(n, s.cols - s.cx)
		for x := s.cols - 1; x >= s.cx + k; x -= 1 do cells[row + x] = cells[row + x - k]
		for x in s.cx ..< s.cx + k do cells[row + x] = blank(s)
	case 'P':
		cells := buf(s)
		row := s.cy * s.cols
		k := min(n, s.cols - s.cx)
		for x in s.cx ..< s.cols - k do cells[row + x] = cells[row + x + k]
		for x in s.cols - k ..< s.cols do cells[row + x] = blank(s)
	case 'L':
		if s.cy >= s.top && s.cy <= s.bottom do scroll_down(s, s.cy, s.bottom, n)
	case 'M':
		if s.cy >= s.top && s.cy <= s.bottom do scroll_up(s, s.cy, s.bottom, n)
	case 'S':
		scroll_up(s, s.top, s.bottom, n)
	case 'T':
		if s.private == 0 do scroll_down(s, s.top, s.bottom, n)
	case 'r':
		if s.private != 0 do return
		top := param(s, 0, 1) - 1
		bottom := param(s, 1, s.rows) - 1
		if top < bottom && bottom < s.rows {
			s.top, s.bottom = top, bottom
			s.cx, s.cy = 0, 0
		}
	case 's':
		if s.private == 0 do save_cursor(s)
	case 'u':
		if s.private == 0 do restore_cursor(s)
	case 'h', 'l':
		set_modes(s, final == 'h')
	case 'm':
		if s.private == 0 do sgr(s)
	}
}

@(private = "file")
set_modes :: proc(s: ^Screen, on: bool) {
	if s.private != '?' do return
	for i in 0 ..< max(s.nparams, 1) {
		switch s.params[i] {
		case 1:
			s.app_cursor = on
		case 7:
			s.autowrap = on
		case 25:
			s.cursor_visible = on
		case 2004:
			s.bracketed_paste = on
		case 47, 1047, 1049:
			if on == s.using_alt do continue
			if on {
				if s.params[i] == 1049 do save_cursor(s)
				s.using_alt = true
				blank_all(s.alt)
			} else {
				s.using_alt = false
				if s.params[i] == 1049 do restore_cursor(s)
			}
		}
	}
}

@(private = "file")
sgr :: proc(s: ^Screen) {
	if s.nparams == 0 {
		s.attr = {}
		return
	}
	i := 0
	for i < s.nparams {
		p := s.params[i]
		switch p {
		case 0: s.attr = {}
		case 1: s.attr.flags |= ATTR_BOLD
		case 2: s.attr.flags |= ATTR_DIM
		case 3: s.attr.flags |= ATTR_ITALIC
		case 4: s.attr.flags |= ATTR_UNDERLINE
		case 7: s.attr.flags |= ATTR_INVERSE
		case 8: s.attr.flags |= ATTR_HIDDEN
		case 9: s.attr.flags |= ATTR_STRIKE
		case 21, 22: s.attr.flags &~= ATTR_BOLD | ATTR_DIM
		case 23: s.attr.flags &~= ATTR_ITALIC
		case 24: s.attr.flags &~= ATTR_UNDERLINE
		case 27: s.attr.flags &~= ATTR_INVERSE
		case 28: s.attr.flags &~= ATTR_HIDDEN
		case 29: s.attr.flags &~= ATTR_STRIKE
		case 30 ..= 37: s.attr.fg = 1 << 24 | u32(p - 30)
		case 39: s.attr.fg = 0
		case 40 ..= 47: s.attr.bg = 1 << 24 | u32(p - 40)
		case 49: s.attr.bg = 0
		case 90 ..= 97: s.attr.fg = 1 << 24 | u32(p - 90 + 8)
		case 100 ..= 107: s.attr.bg = 1 << 24 | u32(p - 100 + 8)
		case 38, 48:
			color: u32
			if i + 2 < s.nparams && s.params[i + 1] == 5 {
				color = 1 << 24 | u32(s.params[i + 2] & 0xff)
				i += 2
			} else if i + 4 < s.nparams && s.params[i + 1] == 2 {
				r, g, b := u32(s.params[i + 2] & 0xff), u32(s.params[i + 3] & 0xff), u32(s.params[i + 4] & 0xff)
				color = 2 << 24 | r << 16 | g << 8 | b
				i += 4
			}
			if p == 38 do s.attr.fg = color
			else do s.attr.bg = color
		}
		i += 1
	}
}

// The visible screen as lines of text, right-trimmed.
screen_lines :: proc(s: ^Screen, allocator := context.temp_allocator) -> []string {
	cells := buf(s)
	lines := make([]string, s.rows, allocator)
	b := strings.builder_make(context.temp_allocator)
	for y in 0 ..< s.rows {
		strings.builder_reset(&b)
		for x in 0 ..< s.cols {
			c := cells[y * s.cols + x]
			if c.ch == 0 do continue
			strings.write_rune(&b, c.ch)
		}
		lines[y] = strings.clone(strings.trim_right_space(strings.to_string(b)), allocator)
	}
	return lines
}

screen_text :: proc(s: ^Screen, allocator := context.temp_allocator) -> string {
	lines := screen_lines(s, context.temp_allocator)
	last := len(lines)
	for last > 0 && lines[last - 1] == "" do last -= 1
	return strings.join(lines[:last], "\n", allocator)
}

@(private = "file")
write_color :: proc(b: ^strings.Builder, color: u32, base: int) {
	kind := color >> 24
	if kind == 1 {
		idx := int(color & 0xff)
		if idx < 8 {
			strings.write_byte(b, ';')
			strings.write_int(b, base + idx)
		} else if idx < 16 {
			strings.write_byte(b, ';')
			strings.write_int(b, base + 60 + idx - 8)
		} else {
			strings.write_byte(b, ';')
			strings.write_int(b, base + 8)
			strings.write_string(b, ";5;")
			strings.write_int(b, idx)
		}
	} else if kind == 2 {
		strings.write_byte(b, ';')
		strings.write_int(b, base + 8)
		strings.write_string(b, ";2;")
		strings.write_int(b, int((color >> 16) & 0xff))
		strings.write_byte(b, ';')
		strings.write_int(b, int((color >> 8) & 0xff))
		strings.write_byte(b, ';')
		strings.write_int(b, int(color & 0xff))
	}
}

@(private = "file")
write_sgr :: proc(b: ^strings.Builder, a: Attr) {
	strings.write_string(b, "\x1b[0")
	if a.flags & ATTR_BOLD != 0 do strings.write_string(b, ";1")
	if a.flags & ATTR_DIM != 0 do strings.write_string(b, ";2")
	if a.flags & ATTR_ITALIC != 0 do strings.write_string(b, ";3")
	if a.flags & ATTR_UNDERLINE != 0 do strings.write_string(b, ";4")
	if a.flags & ATTR_INVERSE != 0 do strings.write_string(b, ";7")
	if a.flags & ATTR_HIDDEN != 0 do strings.write_string(b, ";8")
	if a.flags & ATTR_STRIKE != 0 do strings.write_string(b, ";9")
	write_color(b, a.fg, 30)
	write_color(b, a.bg, 40)
	strings.write_byte(b, 'm')
}

// Bytes that redraw the current screen on a fresh terminal of the same size.
screen_render :: proc(s: ^Screen, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "\x1b[0m\x1b[?25l")
	if s.using_alt do strings.write_string(&b, "\x1b[?1049h")
	strings.write_string(&b, "\x1b[H\x1b[2J")
	cells := buf(s)
	cur := Attr{}
	for y in 0 ..< s.rows {
		row := cells[y * s.cols:(y + 1) * s.cols]
		last := s.cols - 1
		for last >= 0 && row[last].ch == ' ' && row[last].attr == {} do last -= 1
		if last < 0 do continue
		strings.write_string(&b, "\x1b[")
		strings.write_int(&b, y + 1)
		strings.write_string(&b, ";1H")
		for x in 0 ..= last {
			c := row[x]
			if c.ch == 0 do continue
			if c.attr != cur {
				write_sgr(&b, c.attr)
				cur = c.attr
			}
			strings.write_rune(&b, c.ch)
		}
	}
	strings.write_string(&b, "\x1b[0m")
	if s.top != 0 || s.bottom != s.rows - 1 {
		strings.write_string(&b, "\x1b[")
		strings.write_int(&b, s.top + 1)
		strings.write_byte(&b, ';')
		strings.write_int(&b, s.bottom + 1)
		strings.write_byte(&b, 'r')
	}
	if s.attr != {} do write_sgr(&b, s.attr)
	strings.write_string(&b, "\x1b[")
	strings.write_int(&b, s.cy + 1)
	strings.write_byte(&b, ';')
	strings.write_int(&b, s.cx + 1)
	strings.write_byte(&b, 'H')
	if s.bracketed_paste do strings.write_string(&b, "\x1b[?2004h")
	if s.app_cursor do strings.write_string(&b, "\x1b[?1h")
	if s.cursor_visible do strings.write_string(&b, "\x1b[?25h")
	return strings.to_string(b)
}
