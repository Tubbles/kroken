package prompt

// Renders the user prompt from the configured template and describes
// the selection to the model. Pure; the placeholders are documented in
// doc/configuration.md.

import "core:os"
import "core:strings"

Selection :: struct {
	file:          string, // absolute path
	relative_file: string, // relative to the git root, or the base name
	text:          string,
	start_line:    int, // 1-based, 0 when unknown
	end_line:      int, // 1-based inclusive, 0 when unknown
}

// Replaces every `{placeholder}` in `template`. Unknown placeholders are
// left as written so a typo is visible in the run log instead of
// vanishing.
render :: proc(template: string, selection: Selection, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	remaining := template
	for {
		open := strings.index_byte(remaining, '{')
		if open < 0 {
			strings.write_string(&builder, remaining)
			break
		}
		close := strings.index_byte(remaining[open:], '}')
		if close < 0 {
			strings.write_string(&builder, remaining)
			break
		}
		strings.write_string(&builder, remaining[:open])
		name := remaining[open + 1:open + close]
		if write_placeholder(&builder, name, selection) {
			remaining = remaining[open + close + 1:]
		} else {
			// Not a placeholder: keep the brace and rescan from the next
			// byte so `{{selection}}` still resolves the inner one.
			strings.write_byte(&builder, '{')
			remaining = remaining[open + 1:]
		}
	}
	return strings.to_string(builder)
}

@(private)
write_placeholder :: proc(builder: ^strings.Builder, name: string, selection: Selection) -> bool {
	switch name {
	case "file":
		strings.write_string(builder, selection.file)
	case "relative_file":
		strings.write_string(builder, selection.relative_file)
	case "selection":
		strings.write_string(builder, selection.text)
	case "language":
		strings.write_string(builder, language_of(selection.file))
	case "start_line":
		strings.write_int(builder, selection.start_line)
	case "end_line":
		strings.write_int(builder, selection.end_line)
	case "location":
		write_location(builder, selection)
	case:
		return false
	}
	return true
}

// "path, lines 10-20" when the range is known, else just the path.
@(private)
write_location :: proc(builder: ^strings.Builder, selection: Selection) {
	strings.write_string(builder, selection.file)
	if selection.start_line <= 0 {
		return
	}
	strings.write_string(builder, ", line")
	if selection.end_line > selection.start_line {
		strings.write_string(builder, "s ")
		strings.write_int(builder, selection.start_line)
		strings.write_byte(builder, '-')
		strings.write_int(builder, selection.end_line)
	} else {
		strings.write_byte(builder, ' ')
		strings.write_int(builder, selection.start_line)
	}
}

// Maps a file name to a language name for the prompt. Falls back to
// the bare extension, which is still a useful hint.
language_of :: proc(file: string) -> string {
	name := os.base(file)
	switch name {
	case "Makefile", "GNUmakefile", "makefile":
		return "Make"
	case "CMakeLists.txt":
		return "CMake"
	case "Dockerfile":
		return "Dockerfile"
	}
	extension := os.ext(name)
	if extension == "" {
		return "unknown"
	}
	switch extension {
	case ".odin":
		return "Odin"
	case ".c", ".h":
		return "C"
	case ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx":
		return "C++"
	case ".rs":
		return "Rust"
	case ".go":
		return "Go"
	case ".py":
		return "Python"
	case ".js", ".mjs", ".cjs":
		return "JavaScript"
	case ".ts", ".mts", ".cts":
		return "TypeScript"
	case ".tsx", ".jsx":
		return "React"
	case ".java":
		return "Java"
	case ".kt", ".kts":
		return "Kotlin"
	case ".lua":
		return "Lua"
	case ".sh", ".bash":
		return "Shell"
	case ".zig":
		return "Zig"
	case ".rb":
		return "Ruby"
	case ".php":
		return "PHP"
	case ".cs":
		return "C#"
	case ".swift":
		return "Swift"
	case ".md":
		return "Markdown"
	case ".toml":
		return "TOML"
	case ".yaml", ".yml":
		return "YAML"
	case ".json":
		return "JSON"
	case ".html", ".htm":
		return "HTML"
	case ".css":
		return "CSS"
	case ".sql":
		return "SQL"
	case ".nix":
		return "Nix"
	case ".hs":
		return "Haskell"
	case ".ex", ".exs":
		return "Elixir"
	case ".scad":
		return "OpenSCAD"
	case ".lp":
		return "Answer Set Programming"
	}
	return extension[1:]
}
