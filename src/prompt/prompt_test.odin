package prompt

import "core:testing"

@(test)
renders_every_placeholder :: proc(t: ^testing.T) {
	selection := Selection {
		file = "/repo/src/main.odin",
		relative_file = "src/main.odin",
		text = "// fill me\nproc :: proc() {}",
		start_line = 10,
		end_line = 12,
	}
	rendered := render("{file}|{relative_file}|{language}|{start_line}|{end_line}|{location}\n<{selection}>", selection)
	defer delete(rendered)
	testing.expect_value(t, rendered, "/repo/src/main.odin|src/main.odin|Odin|10|12|/repo/src/main.odin, lines 10-12\n<// fill me\nproc :: proc() {}>")
}

@(test)
location_adapts_to_what_is_known :: proc(t: ^testing.T) {
	unknown := render("{location}", Selection{file = "/a.c"})
	defer delete(unknown)
	testing.expect_value(t, unknown, "/a.c")
	single := render("{location}", Selection{file = "/a.c", start_line = 4, end_line = 4})
	defer delete(single)
	testing.expect_value(t, single, "/a.c, line 4")
}

@(test)
unknown_placeholders_and_braces_survive :: proc(t: ^testing.T) {
	rendered := render("{nope} {} {{selection}} {unclosed", Selection{text = "x"})
	defer delete(rendered)
	testing.expect_value(t, rendered, "{nope} {} {x} {unclosed")
}

@(test)
detects_languages :: proc(t: ^testing.T) {
	testing.expect_value(t, language_of("/x/y/main.odin"), "Odin")
	testing.expect_value(t, language_of("lib.hpp"), "C++")
	testing.expect_value(t, language_of("/x/Makefile"), "Make")
	testing.expect_value(t, language_of("weird.xyz"), "xyz")
	testing.expect_value(t, language_of("README"), "unknown")
}
