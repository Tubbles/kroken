package toml

import "core:fmt"
import "core:strings"

// Serializes a tree back to TOML. Tables become `[dotted.headers]`,
// except inside arrays where they are written inline. The output parses
// back to an equivalent tree.
write :: proc(root: ^Table, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	path := make([dynamic]string, allocator)
	defer delete(path)
	write_table_body(&builder, root, &path)
	return strings.to_string(builder)
}

@(private)
write_table_body :: proc(builder: ^strings.Builder, table: ^Table, path: ^[dynamic]string) {
	for key, index in table.keys {
		if _, is_table := table.values[index].(^Table); is_table {
			continue
		}
		write_key(builder, key)
		strings.write_string(builder, " = ")
		write_value(builder, table.values[index])
		strings.write_byte(builder, '\n')
	}
	for key, index in table.keys {
		child, is_table := table.values[index].(^Table)
		if !is_table {
			continue
		}
		append(path, key)
		if strings.builder_len(builder^) > 0 {
			strings.write_byte(builder, '\n')
		}
		strings.write_byte(builder, '[')
		for segment, position in path {
			if position > 0 {
				strings.write_byte(builder, '.')
			}
			write_key(builder, segment)
		}
		strings.write_string(builder, "]\n")
		write_table_body(builder, child, path)
		pop(path)
	}
}

@(private)
write_key :: proc(builder: ^strings.Builder, key: string) {
	bare := len(key) > 0
	for index in 0 ..< len(key) {
		if !is_bare_key_byte(key[index]) {
			bare = false
			break
		}
	}
	if bare {
		strings.write_string(builder, key)
	} else {
		write_basic_string(builder, key, multiline = false)
	}
}

@(private)
write_value :: proc(builder: ^strings.Builder, value: Value) {
	switch inner in value {
	case i64:
		strings.write_i64(builder, inner)
	case f64:
		write_float(builder, inner)
	case bool:
		strings.write_string(builder, inner ? "true" : "false")
	case string:
		write_basic_string(builder, inner, multiline = strings.index_byte(inner, '\n') >= 0)
	case ^Array:
		strings.write_byte(builder, '[')
		for item, index in inner.items {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_value(builder, item)
		}
		strings.write_byte(builder, ']')
	case ^Table:
		strings.write_byte(builder, '{')
		for key, index in inner.keys {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_key(builder, key)
			strings.write_string(builder, " = ")
			write_value(builder, inner.values[index])
		}
		strings.write_byte(builder, '}')
	case nil:
		strings.write_string(builder, "\"\"")
	}
}

// TOML requires a decimal point or exponent in every float, and the
// output should stay readable, so fixed notation with trailing zeros
// trimmed is used.
@(private)
write_float :: proc(builder: ^strings.Builder, value: f64) {
	text := fmt.tprintf("%.6f", value)
	end := len(text)
	for end > 0 && text[end - 1] == '0' {
		end -= 1
	}
	if end > 0 && text[end - 1] == '.' {
		end += 1
	}
	strings.write_string(builder, text[:end])
}

@(private)
write_basic_string :: proc(builder: ^strings.Builder, text: string, multiline: bool) {
	strings.write_string(builder, multiline ? "\"\"\"\n" : "\"")
	for index in 0 ..< len(text) {
		current := text[index]
		switch current {
		case '\\':
			strings.write_string(builder, "\\\\")
		case '"':
			strings.write_string(builder, "\\\"")
		case '\n':
			strings.write_string(builder, multiline ? "\n" : "\\n")
		case '\t':
			strings.write_byte(builder, '\t')
		case '\r':
			strings.write_string(builder, "\\r")
		case 0x08:
			strings.write_string(builder, "\\b")
		case 0x0C:
			strings.write_string(builder, "\\f")
		case:
			if current < 0x20 || current == 0x7F {
				fmt.sbprintf(builder, "\\u%04X", current)
			} else {
				strings.write_byte(builder, current)
			}
		}
	}
	strings.write_string(builder, multiline ? "\"\"\"" : "\"")
}
