package toml

import "core:strings"
import "core:testing"

@(private = "file")
parse_or_fail :: proc(t: ^testing.T, source: string, loc := #caller_location) -> ^Table {
	root, error, ok := parse(source)
	if !ok {
		testing.expectf(t, false, "parse failed at %d:%d: %s", error.line, error.column, error.message, loc = loc)
		return new_table()
	}
	return root
}

@(private = "file")
expect_parse_error :: proc(t: ^testing.T, source: string, expected_message: string, expected_line := 0, loc := #caller_location) {
	root, error, ok := parse(source)
	if ok {
		destroy_table(root)
		testing.expectf(t, false, "expected error %q, but parsing succeeded", expected_message, loc = loc)
		return
	}
	testing.expect_value(t, error.message, expected_message, loc = loc)
	if expected_line > 0 {
		testing.expect_value(t, error.line, expected_line, loc = loc)
	}
}

@(test)
parses_scalars :: proc(t: ^testing.T) {
	root := parse_or_fail(t, `
positive = 42
negative = -7
underscored = 1_000_000
plus = +3
ratio = 0.25
exponent = 1e3
yes = true
no = false
basic = "tab\there \"quoted\" back\\slash \u00e9 \U0001F600"
literal = 'C:\path\no "escapes"'
`)
	defer destroy_table(root)

	positive, _ := get_i64(root, "positive")
	testing.expect_value(t, positive, 42)
	negative, _ := get_i64(root, "negative")
	testing.expect_value(t, negative, -7)
	underscored, _ := get_i64(root, "underscored")
	testing.expect_value(t, underscored, 1_000_000)
	plus, _ := get_i64(root, "plus")
	testing.expect_value(t, plus, 3)
	ratio, _ := get_f64(root, "ratio")
	testing.expect_value(t, ratio, 0.25)
	exponent, _ := get_f64(root, "exponent")
	testing.expect_value(t, exponent, 1000)
	yes, _ := get_bool(root, "yes")
	testing.expect_value(t, yes, true)
	no, _ := get_bool(root, "no")
	testing.expect_value(t, no, false)
	basic, _ := get_string(root, "basic")
	testing.expect_value(t, basic, "tab\there \"quoted\" back\\slash é 😀")
	literal, _ := get_string(root, "literal")
	testing.expect_value(t, literal, `C:\path\no "escapes"`)
}

@(test)
parses_tables_and_dotted_keys :: proc(t: ^testing.T) {
	root := parse_or_fail(t, `
profile = "work"   # trailing comment

[claude]
model = "opus"
tools = ["Read", "Grep"]

[claude.env]
CLAUDE_CONFIG_DIR = "~/.claude-work"

[prompt]
system.short = "yes"
"quoted key".inner = 1
`)
	defer destroy_table(root)

	profile, _ := get_string(root, "profile")
	testing.expect_value(t, profile, "work")
	model, _ := get_string(root, "claude.model")
	testing.expect_value(t, model, "opus")
	config_directory, _ := get_string(root, "claude.env.CLAUDE_CONFIG_DIR")
	testing.expect_value(t, config_directory, "~/.claude-work")
	short, _ := get_string(root, "prompt.system.short")
	testing.expect_value(t, short, "yes")
	inner, _ := get_i64(root, "prompt.quoted key.inner")
	testing.expect_value(t, inner, 1)

	tools, tools_found := get_array(root, "claude.tools")
	testing.expect(t, tools_found)
	testing.expect_value(t, len(tools.items), 2)
	testing.expect_value(t, tools.items[1].(string), "Grep")

	_, missing := get_string(root, "claude.missing")
	testing.expect_value(t, missing, false)
	_, wrong_type := get_i64(root, "claude.model")
	testing.expect_value(t, wrong_type, false)
}

@(test)
parses_multiline_strings :: proc(t: ^testing.T) {
	root := parse_or_fail(t, "basic = \"\"\"\nfirst line\n  second \"line\"\nthird \\\n     joined\"\"\"\nliteral = '''\nraw \\n stays\n'''\nquotes = \"\"\"ends with \"\"\"\"\"\n")
	defer destroy_table(root)

	basic, _ := get_string(root, "basic")
	testing.expect_value(t, basic, "first line\n  second \"line\"\nthird joined")
	literal, _ := get_string(root, "literal")
	testing.expect_value(t, literal, "raw \\n stays\n")
	quotes, _ := get_string(root, "quotes")
	testing.expect_value(t, quotes, "ends with \"\"")
}

@(test)
parses_arrays_and_inline_tables :: proc(t: ^testing.T) {
	root := parse_or_fail(t, `
nested = [
  [1, 2], # comment inside
  ["a", "b"],
]
empty = []
point = { x = 1, y = -2, label = "origin" }
`)
	defer destroy_table(root)

	nested, _ := get_array(root, "nested")
	testing.expect_value(t, len(nested.items), 2)
	first := nested.items[0].(^Array)
	testing.expect_value(t, first.items[1].(i64), 2)
	empty, _ := get_array(root, "empty")
	testing.expect_value(t, len(empty.items), 0)
	label, _ := get_string(root, "point.label")
	testing.expect_value(t, label, "origin")
	y, _ := get_i64(root, "point.y")
	testing.expect_value(t, y, -2)
}

@(test)
reports_errors_with_positions :: proc(t: ^testing.T) {
	expect_parse_error(t, "a = 1\na = 2\n", "duplicate key", expected_line = 2)
	expect_parse_error(t, "[a]\nx = 1\n[a]\n", "table defined more than once", expected_line = 3)
	expect_parse_error(t, "[[items]]\n", "arrays of tables are not supported", expected_line = 1)
	expect_parse_error(t, "s = \"open\n", "newline in single-line string")
	expect_parse_error(t, "s = \"open", "unterminated string")
	expect_parse_error(t, "d = 2026-09-05\n", "date and time values are not supported")
	expect_parse_error(t, "t = 07:32:00\n", "date and time values are not supported")
	expect_parse_error(t, "s = \"bad \\q escape\"\n", "invalid escape sequence")
	expect_parse_error(t, "key\n", "expected '=' after key")
	expect_parse_error(t, "a = 1 b = 2\n", "expected end of line")
	expect_parse_error(t, "a = 1\na.b = 2\n", "key already holds a value that is not a table")
	expect_parse_error(t, "p = { x = 1 }\np.y = 2\n", "inline tables cannot be extended")
	expect_parse_error(t, "h = 0xFF\n", "only decimal integers are supported")
	expect_parse_error(t, "v = [1, 2\n", "unterminated array")
}

@(test)
write_round_trips :: proc(t: ^testing.T) {
	source := `title = "kroken"
count = 3
ratio = 1.5
flag = false
list = ["a", "b"]
multi = """
line one
line "two"
"""

[claude]
model = "opus"

[claude.env]
"odd key!" = "value"

[prompt]
template = "with\ttab and \\ backslash"
`
	root := parse_or_fail(t, source)
	defer destroy_table(root)
	written := write(root)
	defer delete(written)

	reparsed := parse_or_fail(t, written)
	defer destroy_table(reparsed)
	rewritten := write(reparsed)
	defer delete(rewritten)

	testing.expect_value(t, rewritten, written)
	testing.expect(t, strings.contains(written, "\"odd key!\" = \"value\""))
	testing.expect(t, strings.contains(written, "ratio = 1.5\n"))
	testing.expect(t, strings.contains(written, "multi = \"\"\"\nline one\n"))

	multi, _ := get_string(reparsed, "multi")
	testing.expect_value(t, multi, "line one\nline \"two\"\n")
	template, _ := get_string(reparsed, "prompt.template")
	testing.expect_value(t, template, "with\ttab and \\ backslash")
}

@(test)
merge_is_deep_and_source_wins :: proc(t: ^testing.T) {
	destination := parse_or_fail(t, `
profile = "default"
[claude]
model = "opus"
tools = ["Read", "Grep", "Glob"]
[claude.env]
A = "1"
`)
	defer destroy_table(destination)
	source := parse_or_fail(t, `
profile = "work"
[claude]
tools = ["Read"]
[claude.env]
B = "2"
[log]
enabled = false
`)
	defer destroy_table(source)

	merge(destination, source)

	profile, _ := get_string(destination, "profile")
	testing.expect_value(t, profile, "work")
	model, _ := get_string(destination, "claude.model")
	testing.expect_value(t, model, "opus")
	tools, _ := get_array(destination, "claude.tools")
	testing.expect_value(t, len(tools.items), 1)
	a, _ := get_string(destination, "claude.env.A")
	testing.expect_value(t, a, "1")
	b, _ := get_string(destination, "claude.env.B")
	testing.expect_value(t, b, "2")
	enabled, _ := get_bool(destination, "log.enabled")
	testing.expect_value(t, enabled, false)

	// The source is untouched and independent from the destination.
	source_tools, _ := get_array(source, "claude.tools")
	testing.expect_value(t, len(source_tools.items), 1)
	_, source_has_model := get_string(source, "claude.model")
	testing.expect_value(t, source_has_model, false)
}

@(test)
get_f64_accepts_integers :: proc(t: ^testing.T) {
	root := parse_or_fail(t, "budget = 2\n")
	defer destroy_table(root)
	budget, found := get_f64(root, "budget")
	testing.expect(t, found)
	testing.expect_value(t, budget, 2.0)
}
