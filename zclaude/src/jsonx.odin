package zclaude

// Small helpers for reading parsed JSON and writing JSON by hand. Events are
// written directly into a builder, which keeps the hot path (one event per token)
// free of intermediate trees.

import "core:encoding/json"
import "core:io"
import "core:strconv"
import "core:strings"

Value :: json.Value
Object :: json.Object
Array :: json.Array

parse_json :: proc(data: string, allocator := context.temp_allocator) -> (Value, bool) {
	v, err := json.parse_string(data, json.DEFAULT_SPECIFICATION, true, allocator)
	return v, err == .None
}

// Looks up a path of object keys. Missing keys give nil.
jget :: proc(v: Value, keys: ..string) -> Value {
	cur := v
	for k in keys {
		obj, ok := cur.(Object)
		if !ok do return nil
		cur = obj[k] or_else nil
	}
	return cur
}

jstr :: proc(v: Value, keys: ..string) -> string {
	s, _ := jget(v, ..keys).(json.String)
	return string(s)
}

jhas :: proc(v: Value, keys: ..string) -> bool {
	return jget(v, ..keys) != nil
}

jbool :: proc(v: Value, keys: ..string) -> bool {
	b, _ := jget(v, ..keys).(json.Boolean)
	return bool(b)
}

jint :: proc(v: Value, keys: ..string) -> (i64, bool) {
	#partial switch x in jget(v, ..keys) {
	case json.Integer:
		return i64(x), true
	case json.Float:
		return i64(x), true
	}
	return 0, false
}

jarr :: proc(v: Value, keys: ..string) -> Array {
	a, _ := jget(v, ..keys).(Array)
	return a
}

jobj :: proc(v: Value, keys: ..string) -> (Object, bool) {
	o, ok := jget(v, ..keys).(Object)
	return o, ok
}

// Canonical JSON text (keys sorted), used to compare values and to keep them
// beyond the temporary allocator.
to_json :: proc(v: Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	opt := json.Marshal_Options{sort_maps_by_key = true}
	json.marshal_to_builder(&b, v, opt)
	return strings.to_string(b)
}

write_value :: proc(b: ^strings.Builder, v: Value) {
	opt := json.Marshal_Options{sort_maps_by_key = true}
	json.marshal_to_builder(b, v, opt)
}

// ---------- Writing ----------

Jw :: struct {
	b:     ^strings.Builder,
	first: [32]bool,
	depth: int,
}

jw_make :: proc(b: ^strings.Builder) -> Jw {
	return Jw{b = b}
}

@(private = "file")
jw_sep :: proc(w: ^Jw) {
	if w.depth == 0 do return
	if w.first[w.depth] {
		w.first[w.depth] = false
	} else {
		strings.write_byte(w.b, ',')
	}
}

jw_obj :: proc(w: ^Jw) {
	strings.write_byte(w.b, '{')
	w.depth += 1
	w.first[w.depth] = true
}

jw_arr :: proc(w: ^Jw) {
	strings.write_byte(w.b, '[')
	w.depth += 1
	w.first[w.depth] = true
}

jw_end_obj :: proc(w: ^Jw) {
	strings.write_byte(w.b, '}')
	w.depth -= 1
}

jw_end_arr :: proc(w: ^Jw) {
	strings.write_byte(w.b, ']')
	w.depth -= 1
}

// Opens a keyed value inside an object; the caller writes the value next.
jw_key :: proc(w: ^Jw, key: string) {
	jw_sep(w)
	write_quoted(w.b, key)
	strings.write_byte(w.b, ':')
}

// Separator for an array element written with raw helpers.
jw_item :: proc(w: ^Jw) {
	jw_sep(w)
}

jw_str :: proc(w: ^Jw, key: string, s: string) {
	jw_key(w, key)
	write_quoted(w.b, s)
}

jw_int :: proc(w: ^Jw, key: string, n: i64) {
	jw_key(w, key)
	strings.write_i64(w.b, n)
}

jw_bool :: proc(w: ^Jw, key: string, v: bool) {
	jw_key(w, key)
	strings.write_string(w.b, v ? "true" : "false")
}

jw_null :: proc(w: ^Jw, key: string) {
	jw_key(w, key)
	strings.write_string(w.b, "null")
}

// Embeds already-encoded JSON. Empty text is written as null.
jw_raw :: proc(w: ^Jw, key: string, raw: string) {
	jw_key(w, key)
	strings.write_string(w.b, len(raw) > 0 ? raw : "null")
}

jw_value :: proc(w: ^Jw, key: string, v: Value) {
	jw_key(w, key)
	write_value(w.b, v)
}

jw_str_item :: proc(w: ^Jw, s: string) {
	jw_sep(w)
	write_quoted(w.b, s)
}

jw_obj_key :: proc(w: ^Jw, key: string) {
	jw_key(w, key)
	jw_obj(w)
}

jw_arr_key :: proc(w: ^Jw, key: string) {
	jw_key(w, key)
	jw_arr(w)
}

jw_obj_item :: proc(w: ^Jw) {
	jw_sep(w)
	jw_obj(w)
}

HEX := "0123456789abcdef"

// JSON string escaping. Invalid UTF-8 is replaced so output always parses.
write_quoted :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	start := 0
	i := 0
	for i < len(s) {
		ch := s[i]
		if ch >= 0x20 && ch != '"' && ch != '\\' && ch < 0x80 {
			i += 1
			continue
		}
		if ch >= 0x80 {
			r, size := utf8_decode(s[i:])
			if r == 0xFFFD && size == 1 {
				strings.write_string(b, s[start:i])
				strings.write_string(b, "�")
				i += 1
				start = i
				continue
			}
			// U+2028/2029 break JavaScript string literals.
			if r == 0x2028 || r == 0x2029 {
				strings.write_string(b, s[start:i])
				strings.write_string(b, r == 0x2028 ? "\\u2028" : "\\u2029")
				i += size
				start = i
				continue
			}
			i += size
			continue
		}
		strings.write_string(b, s[start:i])
		switch ch {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_string(b, "\\u00")
			strings.write_byte(b, HEX[ch >> 4])
			strings.write_byte(b, HEX[ch & 0xf])
		}
		i += 1
		start = i
	}
	strings.write_string(b, s[start:])
	strings.write_byte(b, '"')
}

// Decodes one UTF-8 sequence. Invalid input gives (0xFFFD, 1).
utf8_decode :: proc(s: string) -> (rune, int) {
	if len(s) == 0 do return 0xFFFD, 0
	b0 := s[0]
	if b0 < 0x80 do return rune(b0), 1
	need := 0
	r: rune
	switch {
	case b0 & 0xE0 == 0xC0:
		need = 1; r = rune(b0 & 0x1F)
		if b0 < 0xC2 do return 0xFFFD, 1
	case b0 & 0xF0 == 0xE0:
		need = 2; r = rune(b0 & 0x0F)
	case b0 & 0xF8 == 0xF0:
		need = 3; r = rune(b0 & 0x07)
		if b0 > 0xF4 do return 0xFFFD, 1
	case:
		return 0xFFFD, 1
	}
	if len(s) < need + 1 do return 0xFFFD, 1
	for k in 1 ..= need {
		c := s[k]
		if c & 0xC0 != 0x80 do return 0xFFFD, 1
		r = (r << 6) | rune(c & 0x3F)
	}
	if need == 2 && (r < 0x800 || (r >= 0xD800 && r <= 0xDFFF)) do return 0xFFFD, 1
	if need == 3 && (r < 0x10000 || r > 0x10FFFF) do return 0xFFFD, 1
	return r, need + 1
}

// Length of a complete UTF-8 prefix of `b`, so a chunk split mid-character can
// carry its tail over to the next read.
utf8_complete_len :: proc(b: []byte) -> int {
	n := len(b)
	// Look back at most 3 bytes for an incomplete lead.
	for back in 1 ..= min(3, n) {
		c := b[n - back]
		if c & 0xC0 == 0x80 do continue // continuation
		need := 0
		switch {
		case c & 0xE0 == 0xC0: need = 2
		case c & 0xF0 == 0xE0: need = 3
		case c & 0xF8 == 0xF0: need = 4
		case: return n
		}
		return back < need ? n - back : n
	}
	return n
}

itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf: [32]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}

_ :: io
