package toml

import "base:runtime"
import "core:strconv"
import "core:strings"

@(private)
Parser :: struct {
	source:     string,
	offset:     int,
	line:       int,
	line_start: int,
	allocator:  runtime.Allocator,
	root:       ^Table,
	current:    ^Table, // the table receiving key/value pairs
	error:      Error,
	failed:     bool,
}

// Parses a TOML document. On failure the partially built tree is freed
// and `error` carries a 1-based line and column.
parse :: proc(source: string, allocator := context.allocator) -> (root: ^Table, error: Error, ok: bool) {
	parser := Parser{source = source, line = 1, allocator = allocator}
	parser.root = new_table(allocator)
	parser.current = parser.root
	for !parser.failed {
		skip_blank_lines(&parser)
		if at_end(&parser) {
			break
		}
		parse_expression(&parser)
	}
	if parser.failed {
		destroy_table(parser.root, allocator)
		return nil, parser.error, false
	}
	return parser.root, {}, true
}

@(private)
at_end :: proc(parser: ^Parser) -> bool {
	return parser.offset >= len(parser.source)
}

@(private)
peek :: proc(parser: ^Parser, ahead := 0) -> u8 {
	position := parser.offset + ahead
	if position >= len(parser.source) {
		return 0
	}
	return parser.source[position]
}

@(private)
advance :: proc(parser: ^Parser) {
	if at_end(parser) {
		return
	}
	if parser.source[parser.offset] == '\n' {
		parser.line += 1
		parser.line_start = parser.offset + 1
	}
	parser.offset += 1
}

@(private)
fail :: proc(parser: ^Parser, message: string) {
	fail_at(parser, parser.line, parser.offset - parser.line_start + 1, message)
}

@(private)
fail_at :: proc(parser: ^Parser, line: int, column: int, message: string) {
	if parser.failed {
		return
	}
	parser.failed = true
	parser.error = Error{line = line, column = column, message = message}
}

@(private)
column_of :: proc(parser: ^Parser) -> int {
	return parser.offset - parser.line_start + 1
}

@(private)
is_newline :: proc(parser: ^Parser) -> bool {
	return peek(parser) == '\n' || (peek(parser) == '\r' && peek(parser, 1) == '\n')
}

@(private)
consume_newline :: proc(parser: ^Parser) {
	if peek(parser) == '\r' {
		advance(parser)
	}
	advance(parser)
}

@(private)
skip_whitespace :: proc(parser: ^Parser) {
	for peek(parser) == ' ' || peek(parser) == '\t' {
		advance(parser)
	}
}

@(private)
skip_comment :: proc(parser: ^Parser) {
	if peek(parser) != '#' {
		return
	}
	for !at_end(parser) && !is_newline(parser) {
		advance(parser)
	}
}

// Skips whitespace, comments, and newlines: everything that may appear
// between two expressions or between array elements.
@(private)
skip_blank_lines :: proc(parser: ^Parser) {
	for {
		skip_whitespace(parser)
		skip_comment(parser)
		if !is_newline(parser) {
			return
		}
		consume_newline(parser)
	}
}

@(private)
expect_end_of_line :: proc(parser: ^Parser) {
	skip_whitespace(parser)
	skip_comment(parser)
	if at_end(parser) {
		return
	}
	if is_newline(parser) {
		consume_newline(parser)
		return
	}
	fail(parser, "expected end of line")
}

@(private)
parse_expression :: proc(parser: ^Parser) {
	if peek(parser) == '[' {
		if peek(parser, 1) == '[' {
			fail(parser, "arrays of tables are not supported")
			return
		}
		parse_table_header(parser)
	} else {
		parse_key_value(parser, parser.current)
	}
	if !parser.failed {
		expect_end_of_line(parser)
	}
}

@(private)
is_bare_key_byte :: proc(byte_value: u8) -> bool {
	switch byte_value {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		return true
	}
	return false
}

// Parses a possibly dotted key into owned parts. The caller frees them
// with `free_key_parts`.
@(private)
parse_key :: proc(parser: ^Parser) -> (parts: [dynamic]string) {
	parts = make([dynamic]string, parser.allocator)
	for {
		part, ok := parse_simple_key(parser)
		if !ok {
			return
		}
		append(&parts, part)
		skip_whitespace(parser)
		if peek(parser) != '.' {
			return
		}
		advance(parser)
		skip_whitespace(parser)
	}
}

@(private)
free_key_parts :: proc(parser: ^Parser, parts: ^[dynamic]string) {
	for part in parts {
		delete(part, parser.allocator)
	}
	delete(parts^)
}

@(private)
parse_simple_key :: proc(parser: ^Parser) -> (key: string, ok: bool) {
	switch peek(parser) {
	case '"':
		if peek(parser, 1) == '"' && peek(parser, 2) == '"' {
			fail(parser, "multi-line strings cannot be used as keys")
			return "", false
		}
		return parse_basic_string(parser)
	case '\'':
		if peek(parser, 1) == '\'' && peek(parser, 2) == '\'' {
			fail(parser, "multi-line strings cannot be used as keys")
			return "", false
		}
		return parse_literal_string(parser)
	}
	start := parser.offset
	for is_bare_key_byte(peek(parser)) {
		advance(parser)
	}
	if parser.offset == start {
		fail(parser, "expected a key")
		return "", false
	}
	return strings.clone(parser.source[start:parser.offset], parser.allocator), true
}

// Returns the table stored under `key` in `table`, creating an implicit
// one when missing. Fails when the key holds something else or an
// inline table, which the specification forbids extending.
@(private)
descend :: proc(parser: ^Parser, table: ^Table, key: string, line: int, column: int) -> (child: ^Table, ok: bool) {
	if existing, found := table_get(table, key); found {
		existing_table, is_table := existing.(^Table)
		if !is_table {
			fail_at(parser, line, column, "key already holds a value that is not a table")
			return nil, false
		}
		if existing_table.inline {
			fail_at(parser, line, column, "inline tables cannot be extended")
			return nil, false
		}
		return existing_table, true
	}
	created := new_table(parser.allocator)
	table_set(table, key, created, parser.allocator)
	return created, true
}

@(private)
parse_key_value :: proc(parser: ^Parser, table: ^Table) {
	key_line := parser.line
	key_column := column_of(parser)
	parts := parse_key(parser)
	defer free_key_parts(parser, &parts)
	if parser.failed {
		return
	}
	skip_whitespace(parser)
	if peek(parser) != '=' {
		fail(parser, "expected '=' after key")
		return
	}
	advance(parser)
	skip_whitespace(parser)
	value, value_ok := parse_value(parser)
	if !value_ok {
		return
	}
	target := table
	for part in parts[:len(parts) - 1] {
		next, descend_ok := descend(parser, target, part, key_line, key_column)
		if !descend_ok {
			destroy_value(value, parser.allocator)
			return
		}
		target = next
	}
	last := parts[len(parts) - 1]
	if _, exists := table_index(target, last); exists {
		fail_at(parser, key_line, key_column, "duplicate key")
		destroy_value(value, parser.allocator)
		return
	}
	table_set(target, last, value, parser.allocator)
}

@(private)
parse_table_header :: proc(parser: ^Parser) {
	header_line := parser.line
	header_column := column_of(parser)
	advance(parser) // '['
	skip_whitespace(parser)
	parts := parse_key(parser)
	defer free_key_parts(parser, &parts)
	if parser.failed {
		return
	}
	skip_whitespace(parser)
	if peek(parser) != ']' {
		fail(parser, "expected ']' to close the table header")
		return
	}
	advance(parser)

	target := parser.root
	for part in parts[:len(parts) - 1] {
		next, ok := descend(parser, target, part, header_line, header_column)
		if !ok {
			return
		}
		target = next
	}
	last := parts[len(parts) - 1]
	if existing, found := table_get(target, last); found {
		existing_table, is_table := existing.(^Table)
		if !is_table {
			fail_at(parser, header_line, header_column, "table header conflicts with an existing key")
			return
		}
		if existing_table.explicit {
			fail_at(parser, header_line, header_column, "table defined more than once")
			return
		}
		if existing_table.inline {
			fail_at(parser, header_line, header_column, "inline tables cannot be extended")
			return
		}
		existing_table.explicit = true
		parser.current = existing_table
		return
	}
	created := new_table(parser.allocator)
	created.explicit = true
	table_set(target, last, created, parser.allocator)
	parser.current = created
}

@(private)
parse_value :: proc(parser: ^Parser) -> (value: Value, ok: bool) {
	switch first := peek(parser); first {
	case '"':
		if peek(parser, 1) == '"' && peek(parser, 2) == '"' {
			text := parse_multiline_basic_string(parser) or_return
			return text, true
		}
		text := parse_basic_string(parser) or_return
		return text, true
	case '\'':
		if peek(parser, 1) == '\'' && peek(parser, 2) == '\'' {
			text := parse_multiline_literal_string(parser) or_return
			return text, true
		}
		text := parse_literal_string(parser) or_return
		return text, true
	case '[':
		array := parse_array(parser) or_return
		return array, true
	case '{':
		table := parse_inline_table(parser) or_return
		return table, true
	case 't', 'f':
		return parse_boolean(parser)
	case '+', '-', '0' ..= '9':
		return parse_number(parser)
	}
	fail(parser, "expected a value")
	return nil, false
}

@(private)
is_value_delimiter :: proc(byte_value: u8) -> bool {
	switch byte_value {
	case 0, ' ', '\t', '\r', '\n', ',', ']', '}', '#':
		return true
	}
	return false
}

@(private)
parse_boolean :: proc(parser: ^Parser) -> (value: Value, ok: bool) {
	rest := parser.source[parser.offset:]
	if strings.has_prefix(rest, "true") && is_value_delimiter(peek(parser, 4)) {
		for _ in 0 ..< 4 {
			advance(parser)
		}
		return true, true
	}
	if strings.has_prefix(rest, "false") && is_value_delimiter(peek(parser, 5)) {
		for _ in 0 ..< 5 {
			advance(parser)
		}
		return false, true
	}
	fail(parser, "expected a value")
	return nil, false
}

@(private)
looks_like_date :: proc(token: string) -> bool {
	if strings.index_byte(token, ':') >= 0 {
		return true
	}
	return len(token) >= 10 && token[4] == '-' && token[7] == '-'
}

@(private)
parse_number :: proc(parser: ^Parser) -> (value: Value, ok: bool) {
	start := parser.offset
	for !at_end(parser) && !is_value_delimiter(peek(parser)) {
		advance(parser)
	}
	token := parser.source[start:parser.offset]
	if looks_like_date(token) {
		fail(parser, "date and time values are not supported")
		return nil, false
	}
	if strings.contains(token, "inf") || strings.contains(token, "nan") {
		fail(parser, "inf and nan are not supported")
		return nil, false
	}
	negative := token[0] == '-'
	digits := token
	if token[0] == '-' || token[0] == '+' {
		digits = token[1:]
	}
	if strings.has_prefix(digits, "0x") || strings.has_prefix(digits, "0o") || strings.has_prefix(digits, "0b") {
		fail(parser, "only decimal integers are supported")
		return nil, false
	}
	cleaned, cleaned_allocated := strings.remove_all(digits, "_", parser.allocator)
	defer if cleaned_allocated {
		delete(cleaned, parser.allocator)
	}
	if len(cleaned) == 0 {
		fail(parser, "invalid number")
		return nil, false
	}
	is_float := strings.index_byte(cleaned, '.') >= 0 || strings.index_byte(cleaned, 'e') >= 0 || strings.index_byte(cleaned, 'E') >= 0
	if is_float {
		float_value, float_ok := strconv.parse_f64(cleaned)
		if !float_ok {
			fail(parser, "invalid float")
			return nil, false
		}
		return negative ? -float_value : float_value, true
	}
	unsigned_value, integer_ok := strconv.parse_u64_of_base(cleaned, 10)
	if !integer_ok || unsigned_value > u64(max(i64)) {
		fail(parser, "invalid integer")
		return nil, false
	}
	integer_value := i64(unsigned_value)
	return negative ? -integer_value : integer_value, true
}

@(private)
finish_string :: proc(parser: ^Parser, builder: ^strings.Builder) -> string {
	text := strings.clone(strings.to_string(builder^), parser.allocator)
	strings.builder_destroy(builder)
	return text
}

@(private)
parse_basic_string :: proc(parser: ^Parser) -> (text: string, ok: bool) {
	advance(parser) // opening quote
	builder := strings.builder_make(parser.allocator)
	for {
		if at_end(parser) {
			fail(parser, "unterminated string")
			strings.builder_destroy(&builder)
			return "", false
		}
		current := peek(parser)
		switch current {
		case '"':
			advance(parser)
			return finish_string(parser, &builder), true
		case '\n', '\r':
			fail(parser, "newline in single-line string")
			strings.builder_destroy(&builder)
			return "", false
		case '\\':
			advance(parser)
			if !parse_escape(parser, &builder, allow_line_ending = false) {
				strings.builder_destroy(&builder)
				return "", false
			}
		case:
			strings.write_byte(&builder, current)
			advance(parser)
		}
	}
}

@(private)
parse_multiline_basic_string :: proc(parser: ^Parser) -> (text: string, ok: bool) {
	for _ in 0 ..< 3 {
		advance(parser)
	}
	if is_newline(parser) {
		consume_newline(parser)
	}
	builder := strings.builder_make(parser.allocator)
	for {
		if at_end(parser) {
			fail(parser, "unterminated multi-line string")
			strings.builder_destroy(&builder)
			return "", false
		}
		if peek(parser) == '"' && peek(parser, 1) == '"' && peek(parser, 2) == '"' {
			for _ in 0 ..< 3 {
				advance(parser)
			}
			// Up to two quotes right before the delimiter belong to the content.
			for extra := 0; extra < 2 && peek(parser) == '"'; extra += 1 {
				strings.write_byte(&builder, '"')
				advance(parser)
			}
			return finish_string(parser, &builder), true
		}
		current := peek(parser)
		if current == '\\' {
			advance(parser)
			if !parse_escape(parser, &builder, allow_line_ending = true) {
				strings.builder_destroy(&builder)
				return "", false
			}
			continue
		}
		strings.write_byte(&builder, current)
		advance(parser)
	}
}

@(private)
parse_literal_string :: proc(parser: ^Parser) -> (text: string, ok: bool) {
	advance(parser) // opening quote
	start := parser.offset
	for {
		if at_end(parser) {
			fail(parser, "unterminated string")
			return "", false
		}
		current := peek(parser)
		if current == '\'' {
			text = strings.clone(parser.source[start:parser.offset], parser.allocator)
			advance(parser)
			return text, true
		}
		if current == '\n' || current == '\r' {
			fail(parser, "newline in single-line string")
			return "", false
		}
		advance(parser)
	}
}

@(private)
parse_multiline_literal_string :: proc(parser: ^Parser) -> (text: string, ok: bool) {
	for _ in 0 ..< 3 {
		advance(parser)
	}
	if is_newline(parser) {
		consume_newline(parser)
	}
	start := parser.offset
	for {
		if at_end(parser) {
			fail(parser, "unterminated multi-line string")
			return "", false
		}
		if peek(parser) == '\'' && peek(parser, 1) == '\'' && peek(parser, 2) == '\'' {
			end := parser.offset
			for _ in 0 ..< 3 {
				advance(parser)
			}
			for extra := 0; extra < 2 && peek(parser) == '\''; extra += 1 {
				end += 1
				advance(parser)
			}
			return strings.clone(parser.source[start:end], parser.allocator), true
		}
		advance(parser)
	}
}

// Parses the character(s) after a backslash inside a basic string.
@(private)
parse_escape :: proc(parser: ^Parser, builder: ^strings.Builder, allow_line_ending: bool) -> bool {
	switch peek(parser) {
	case 'b':
		strings.write_byte(builder, 0x08)
	case 't':
		strings.write_byte(builder, '\t')
	case 'n':
		strings.write_byte(builder, '\n')
	case 'f':
		strings.write_byte(builder, 0x0C)
	case 'r':
		strings.write_byte(builder, '\r')
	case '"':
		strings.write_byte(builder, '"')
	case '\\':
		strings.write_byte(builder, '\\')
	case 'u':
		advance(parser)
		return parse_unicode_escape(parser, builder, 4)
	case 'U':
		advance(parser)
		return parse_unicode_escape(parser, builder, 8)
	case ' ', '\t', '\r', '\n':
		if !allow_line_ending {
			fail(parser, "invalid escape sequence")
			return false
		}
		// Line-ending backslash: trims everything up to the next
		// non-whitespace character, but only if a newline follows.
		skip_whitespace(parser)
		if !is_newline(parser) {
			fail(parser, "invalid escape sequence")
			return false
		}
		skip_blank_lines_without_comments(parser)
		return true
	case:
		fail(parser, "invalid escape sequence")
		return false
	}
	advance(parser)
	return true
}

@(private)
skip_blank_lines_without_comments :: proc(parser: ^Parser) {
	for {
		skip_whitespace(parser)
		if !is_newline(parser) {
			return
		}
		consume_newline(parser)
	}
}

@(private)
parse_unicode_escape :: proc(parser: ^Parser, builder: ^strings.Builder, digit_count: int) -> bool {
	code_point := 0
	for _ in 0 ..< digit_count {
		digit := peek(parser)
		value := 0
		switch digit {
		case '0' ..= '9':
			value = int(digit - '0')
		case 'a' ..= 'f':
			value = int(digit - 'a') + 10
		case 'A' ..= 'F':
			value = int(digit - 'A') + 10
		case:
			fail(parser, "invalid unicode escape")
			return false
		}
		code_point = code_point * 16 + value
		advance(parser)
	}
	if _, error := strings.write_rune(builder, rune(code_point)); error != nil {
		fail(parser, "invalid unicode escape")
		return false
	}
	return true
}

@(private)
parse_array :: proc(parser: ^Parser) -> (array: ^Array, ok: bool) {
	advance(parser) // '['
	array = new_array(parser.allocator)
	for {
		skip_blank_lines(parser)
		if at_end(parser) {
			fail(parser, "unterminated array")
			destroy_value(array, parser.allocator)
			return nil, false
		}
		if peek(parser) == ']' {
			advance(parser)
			return array, true
		}
		item, item_ok := parse_value(parser)
		if !item_ok {
			destroy_value(array, parser.allocator)
			return nil, false
		}
		append(&array.items, item)
		skip_blank_lines(parser)
		if at_end(parser) {
			fail(parser, "unterminated array")
			destroy_value(array, parser.allocator)
			return nil, false
		}
		if peek(parser) == ',' {
			advance(parser)
			continue
		}
		if peek(parser) == ']' {
			advance(parser)
			return array, true
		}
		fail(parser, "expected ',' or ']' in array")
		destroy_value(array, parser.allocator)
		return nil, false
	}
}

@(private)
parse_inline_table :: proc(parser: ^Parser) -> (table: ^Table, ok: bool) {
	advance(parser) // '{'
	table = new_table(parser.allocator)
	table.inline = true
	table.explicit = true
	skip_whitespace(parser)
	if peek(parser) == '}' {
		advance(parser)
		return table, true
	}
	for {
		skip_whitespace(parser)
		parse_key_value(parser, table)
		if parser.failed {
			destroy_table(table, parser.allocator)
			return nil, false
		}
		skip_whitespace(parser)
		if peek(parser) == ',' {
			advance(parser)
			skip_whitespace(parser)
			if peek(parser) == '}' {
				advance(parser)
				return table, true
			}
			continue
		}
		if peek(parser) == '}' {
			advance(parser)
			return table, true
		}
		fail(parser, "expected ',' or '}' in inline table")
		destroy_table(table, parser.allocator)
		return nil, false
	}
}
