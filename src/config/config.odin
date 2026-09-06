package config

// The typed configuration, its defaults, the conversion from the parsed
// tree, and the dump for `kroken config`. Discovery and layering live
// in discover.odin, tree operations in sjson.odin. The schema is
// documented in doc/configuration.md; keep both in sync.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:slice"
import "core:strconv"
import "core:strings"

Config :: struct {
	profile: string,
	backend: string, // which backend runs the completion; the CLI owns the list
	claude:  Claude_Config,
	codex:   Codex_Config,
	prompt:  Prompt_Config,
	log:     Log_Config,
	// Strings this config allocated itself (multi-line prompt text
	// joined from an array); everything else borrows from the tree.
	allocated_text: [dynamic]string,
}

Claude_Config :: struct {
	command:         string,
	model:           string, // "" leaves the choice to claude
	effort:          string, // "" leaves the choice to claude
	tools:           []string,
	extra_args:      []string,
	env:             []Env_Entry, // sorted by name
	persist_session: bool,
	max_budget_usd:  f64, // 0 means no cap
	add_git_root:    bool,
}

Codex_Config :: struct {
	command:             string,
	model:               string, // "" leaves the choice to codex
	effort:              string, // "" leaves the choice to codex
	sandbox:             string, // read-only, workspace-write, danger-full-access
	extra_args:          []string,
	env:                 []Env_Entry, // sorted by name
	persist_session:     bool,
	skip_git_repo_check: bool,
}

Env_Entry :: struct {
	name:  string,
	value: string,
}

Prompt_Config :: struct {
	system:   string,
	template: string,
}

Log_Config :: struct {
	enabled:   bool,
	directory: string, // "" means $XDG_STATE_HOME/kroken/log
}

DEFAULT_BACKEND :: "claude"
DEFAULT_COMMAND :: "claude"
DEFAULT_TOOLS :: []string{"Read", "Grep", "Glob"}
DEFAULT_CODEX_COMMAND :: "codex"
DEFAULT_CODEX_SANDBOX :: "read-only"

DEFAULT_SYSTEM_PROMPT :: `You are kroken, a code completion engine driven from a text editor.

The user selected a region of a source file and sent it to you together with the file path. The selection expresses an intent: a comment describing what code should do, an empty function skeleton to fill in, a TODO to resolve, or code to change. Produce the text that replaces the selection.

Rules:
- Return only the replacement text, exactly as it should appear in the file. No explanation, no markdown fences.
- Keep the parts of the selection that are not the intent itself, such as a surrounding signature, unless the intent asks to change them. Keep comments that document the code. Drop comments that are only instructions to you.
- Match the indentation, line ending style, and conventions of the surrounding file.
- You may read other files in the repository for context. Never modify any file.
- Follow every CLAUDE.md instruction that applies to the file.
`

DEFAULT_TEMPLATE :: `File: {location}
Language: {language}

<selection>
{selection}
</selection>

Replace the selection according to the intent it expresses.
`

// The slices are allocated so `destroy_config` can free them uniformly;
// the strings are literals or borrowed from the tree the config was
// built from, except those listed in `allocated_text`.
default_config :: proc(allocator := context.allocator) -> Config {
	return Config {
		backend = DEFAULT_BACKEND,
		claude = Claude_Config {
			command = DEFAULT_COMMAND,
			tools = slice.clone(DEFAULT_TOOLS, allocator),
			extra_args = make([]string, 0, allocator),
			env = make([]Env_Entry, 0, allocator),
			add_git_root = true,
		},
		codex = Codex_Config {
			command = DEFAULT_CODEX_COMMAND,
			sandbox = DEFAULT_CODEX_SANDBOX,
			extra_args = make([]string, 0, allocator),
			env = make([]Env_Entry, 0, allocator),
			skip_git_repo_check = true,
		},
		prompt = Prompt_Config{system = DEFAULT_SYSTEM_PROMPT, template = DEFAULT_TEMPLATE},
		log = Log_Config{enabled = true},
		allocated_text = make([dynamic]string, allocator),
	}
}

destroy_config :: proc(config: ^Config, allocator := context.allocator) {
	delete(config.claude.tools, allocator)
	delete(config.claude.extra_args, allocator)
	delete(config.claude.env, allocator)
	delete(config.codex.extra_args, allocator)
	delete(config.codex.env, allocator)
	for text in config.allocated_text {
		delete(text, allocator)
	}
	delete(config.allocated_text)
	config^ = {}
}

// Converts a merged tree into a typed config, starting from the
// defaults. Unknown keys and wrong types are errors so typos surface
// instead of being silently ignored. Strings in the result borrow from
// `root`, which must outlive the config.
from_object :: proc(root: json.Object, allocator := context.allocator) -> (config: Config, message: string, ok: bool) {
	config = default_config(allocator)
	reader := Reader{allocator = allocator, config = &config}
	fill_from_object(&reader, root)
	if reader.failed {
		destroy_config(&config, allocator)
		return {}, reader.message, false
	}
	return config, "", true
}

// Collects the first error while the typed fields are filled in, so the
// readers below stay short.
@(private)
Reader :: struct {
	allocator: runtime.Allocator,
	config:    ^Config,
	message:   string,
	failed:    bool,
}

@(private)
fail :: proc(reader: ^Reader, message: string) {
	if reader.failed {
		delete(message, reader.allocator)
		return
	}
	reader.failed = true
	reader.message = message
}

@(private)
fail_type :: proc(reader: ^Reader, prefix: string, key: string, expectation: string) {
	fail(reader, fmt.aprintf("%s%s must be %s", prefix, key, expectation, allocator = reader.allocator))
}

@(private)
fill_from_object :: proc(reader: ^Reader, root: json.Object) {
	config := reader.config
	check_known_keys(reader, root, "", {"profile", "backend", "claude", "codex", "prompt", "log", "profiles"})
	read_string(reader, root, "", "profile", &config.profile)
	read_string(reader, root, "", "backend", &config.backend)

	if claude, found := section(reader, root, "claude"); found {
		check_known_keys(reader, claude, "claude.", {"command", "model", "effort", "tools", "extra_args", "env", "persist_session", "max_budget_usd", "add_git_root"})
		read_string(reader, claude, "claude.", "command", &config.claude.command)
		read_string(reader, claude, "claude.", "model", &config.claude.model)
		read_string(reader, claude, "claude.", "effort", &config.claude.effort)
		read_string_list(reader, claude, "claude.", "tools", &config.claude.tools)
		read_string_list(reader, claude, "claude.", "extra_args", &config.claude.extra_args)
		read_env(reader, claude, "claude.", "env", &config.claude.env)
		read_bool(reader, claude, "claude.", "persist_session", &config.claude.persist_session)
		read_f64(reader, claude, "claude.", "max_budget_usd", &config.claude.max_budget_usd)
		read_bool(reader, claude, "claude.", "add_git_root", &config.claude.add_git_root)
	}
	if codex, found := section(reader, root, "codex"); found {
		check_known_keys(reader, codex, "codex.", {"command", "model", "effort", "sandbox", "extra_args", "env", "persist_session", "skip_git_repo_check"})
		read_string(reader, codex, "codex.", "command", &config.codex.command)
		read_string(reader, codex, "codex.", "model", &config.codex.model)
		read_string(reader, codex, "codex.", "effort", &config.codex.effort)
		read_string(reader, codex, "codex.", "sandbox", &config.codex.sandbox)
		read_string_list(reader, codex, "codex.", "extra_args", &config.codex.extra_args)
		read_env(reader, codex, "codex.", "env", &config.codex.env)
		read_bool(reader, codex, "codex.", "persist_session", &config.codex.persist_session)
		read_bool(reader, codex, "codex.", "skip_git_repo_check", &config.codex.skip_git_repo_check)
	}
	if prompt, found := section(reader, root, "prompt"); found {
		check_known_keys(reader, prompt, "prompt.", {"system", "template"})
		read_text(reader, prompt, "prompt.", "system", &config.prompt.system)
		read_text(reader, prompt, "prompt.", "template", &config.prompt.template)
	}
	if log, found := section(reader, root, "log"); found {
		check_known_keys(reader, log, "log.", {"enabled", "directory"})
		read_bool(reader, log, "log.", "enabled", &config.log.enabled)
		read_string(reader, log, "log.", "directory", &config.log.directory)
	}
	if reader.failed {
		return
	}
	if config.backend == "" {
		fail(reader, strings.clone("backend must not be empty", reader.allocator))
	} else if config.claude.command == "" {
		fail(reader, strings.clone("claude.command must not be empty", reader.allocator))
	} else if config.codex.command == "" {
		fail(reader, strings.clone("codex.command must not be empty", reader.allocator))
	}
}

// Replaces "~/" in the environment values of every backend, since the
// child processes will not. The expansions are owned by the config.
expand_env_homes :: proc(config: ^Config, home: string, allocator := context.allocator) {
	expand_entries(config, config.claude.env, home, allocator)
	expand_entries(config, config.codex.env, home, allocator)
}

@(private)
expand_entries :: proc(config: ^Config, entries: []Env_Entry, home: string, allocator := context.allocator) {
	for &entry in entries {
		if !strings.has_prefix(entry.value, "~") {
			continue
		}
		expanded := expand_home(entry.value, home, allocator)
		append(&config.allocated_text, expanded)
		entry.value = expanded
	}
}

@(private)
check_known_keys :: proc(reader: ^Reader, object: json.Object, prefix: string, known: []string) {
	keys := sorted_keys(object, reader.allocator)
	defer delete(keys, reader.allocator)
	for key in keys {
		if !slice.contains(known, key) {
			fail(reader, fmt.aprintf("unknown key %s%s", prefix, key, allocator = reader.allocator))
			return
		}
	}
}

// found=false when the section is absent; a present non-object fails.
@(private)
section :: proc(reader: ^Reader, root: json.Object, key: string) -> (object: json.Object, found: bool) {
	value, present := root[key]
	if !present {
		return nil, false
	}
	table, is_object := value.(json.Object)
	if !is_object {
		fail_type(reader, "", key, "an object")
		return nil, false
	}
	return table, true
}

@(private)
read_string :: proc(reader: ^Reader, object: json.Object, prefix: string, key: string, destination: ^string) {
	value, present := object[key]
	if !present {
		return
	}
	text, is_string := value.(json.String)
	if !is_string {
		fail_type(reader, prefix, key, "a string")
		return
	}
	destination^ = string(text)
}

// A string, or an array of strings joined with newlines and ending in
// one, which is how multi-line prompt text is written in SJSON.
@(private)
read_text :: proc(reader: ^Reader, object: json.Object, prefix: string, key: string, destination: ^string) {
	value, present := object[key]
	if !present {
		return
	}
	if text, is_string := value.(json.String); is_string {
		destination^ = string(text)
		return
	}
	lines, is_array := value.(json.Array)
	if !is_array {
		fail_type(reader, prefix, key, "a string or an array of strings")
		return
	}
	builder := strings.builder_make(reader.allocator)
	for line in lines {
		text, is_string := line.(json.String)
		if !is_string {
			strings.builder_destroy(&builder)
			fail_type(reader, prefix, key, "a string or an array of strings")
			return
		}
		strings.write_string(&builder, string(text))
		strings.write_byte(&builder, '\n')
	}
	joined := strings.clone(strings.to_string(builder), reader.allocator)
	strings.builder_destroy(&builder)
	append(&reader.config.allocated_text, joined)
	destination^ = joined
}

@(private)
read_bool :: proc(reader: ^Reader, object: json.Object, prefix: string, key: string, destination: ^bool) {
	value, present := object[key]
	if !present {
		return
	}
	flag, is_bool := value.(json.Boolean)
	if !is_bool {
		fail_type(reader, prefix, key, "true or false")
		return
	}
	destination^ = bool(flag)
}

@(private)
read_f64 :: proc(reader: ^Reader, object: json.Object, prefix: string, key: string, destination: ^f64) {
	value, present := object[key]
	if !present {
		return
	}
	#partial switch number in value {
	case json.Float:
		destination^ = f64(number)
	case json.Integer:
		destination^ = f64(number)
	case:
		fail_type(reader, prefix, key, "a number")
	}
}

@(private)
read_string_list :: proc(reader: ^Reader, object: json.Object, prefix: string, key: string, destination: ^[]string) {
	value, present := object[key]
	if !present {
		return
	}
	array, is_array := value.(json.Array)
	if !is_array {
		fail_type(reader, prefix, key, "an array of strings")
		return
	}
	items := make([]string, len(array), reader.allocator)
	for item, index in array {
		text, is_string := item.(json.String)
		if !is_string {
			delete(items, reader.allocator)
			fail_type(reader, prefix, key, "an array of strings")
			return
		}
		items[index] = string(text)
	}
	delete(destination^, reader.allocator)
	destination^ = items
}

@(private)
read_env :: proc(reader: ^Reader, object: json.Object, prefix: string, key: string, destination: ^[]Env_Entry) {
	value, present := object[key]
	if !present {
		return
	}
	env_object, is_object := value.(json.Object)
	if !is_object {
		fail_type(reader, prefix, key, "an object of strings")
		return
	}
	names := sorted_keys(env_object, reader.allocator)
	defer delete(names, reader.allocator)
	entries := make([]Env_Entry, len(names), reader.allocator)
	for name, index in names {
		text, is_string := env_object[name].(json.String)
		if !is_string {
			delete(entries, reader.allocator)
			fail_type(reader, prefix, key, "an object of strings")
			return
		}
		entries[index] = Env_Entry{name = name, value = string(text)}
	}
	delete(destination^, reader.allocator)
	destination^ = entries
}

// Mirrors Config in the shape the files use, for json.marshal: env as
// an object, multi-line prompt text as arrays of lines.
@(private)
Dump :: struct {
	profile: string,
	backend: string,
	claude:  Dump_Claude,
	codex:   Dump_Codex,
	prompt:  Dump_Prompt,
	log:     Log_Config,
}

@(private)
Dump_Codex :: struct {
	command:             string,
	model:               string,
	effort:              string,
	sandbox:             string,
	extra_args:          []string,
	env:                 map[string]string,
	persist_session:     bool,
	skip_git_repo_check: bool,
}

@(private)
Dump_Claude :: struct {
	command:         string,
	model:           string,
	effort:          string,
	tools:           []string,
	extra_args:      []string,
	env:             map[string]string,
	persist_session: bool,
	max_budget_usd:  f64,
	add_git_root:    bool,
}

@(private)
Dump_Prompt :: struct {
	system:   []string,
	template: []string,
}

// Renders every effective value, defaults included, as SJSON that
// parses back to the same configuration.
dump :: proc(config: Config, allocator := context.allocator) -> (text: string, ok: bool) {
	ensure_float_marshaler()
	env := env_map(config.claude.env, allocator)
	defer delete(env)
	codex_env := env_map(config.codex.env, allocator)
	defer delete(codex_env)
	system_lines := text_lines(config.prompt.system, allocator)
	defer delete(system_lines, allocator)
	template_lines := text_lines(config.prompt.template, allocator)
	defer delete(template_lines, allocator)

	value := Dump {
		profile = config.profile,
		backend = config.backend,
		codex = Dump_Codex {
			command = config.codex.command,
			model = config.codex.model,
			effort = config.codex.effort,
			sandbox = config.codex.sandbox,
			extra_args = config.codex.extra_args,
			env = codex_env,
			persist_session = config.codex.persist_session,
			skip_git_repo_check = config.codex.skip_git_repo_check,
		},
		claude = Dump_Claude {
			command = config.claude.command,
			model = config.claude.model,
			effort = config.claude.effort,
			tools = config.claude.tools,
			extra_args = config.claude.extra_args,
			env = env,
			persist_session = config.claude.persist_session,
			max_budget_usd = config.claude.max_budget_usd,
			add_git_root = config.claude.add_git_root,
		},
		prompt = Dump_Prompt{system = system_lines, template = template_lines},
		log = config.log,
	}
	options := json.Marshal_Options {
		spec                      = .MJSON,
		pretty                    = true,
		use_spaces                = true,
		spaces                    = 4,
		mjson_keys_use_equal_sign = true,
		sort_maps_by_key          = true,
	}
	data, error := json.marshal(value, options, allocator)
	if error != nil {
		return "", false
	}
	return string(data), true
}

@(private)
env_map :: proc(entries: []Env_Entry, allocator := context.allocator) -> map[string]string {
	result := make(map[string]string, allocator)
	for entry in entries {
		result[entry.name] = entry.value
	}
	return result
}

// Splits text into lines the array form reproduces: a trailing newline
// is implied by the array form, so it does not become an empty line.
@(private)
text_lines :: proc(text: string, allocator := context.allocator) -> []string {
	lines, _ := strings.split(text, "\n", allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		return lines[:len(lines) - 1]
	}
	return lines
}

// json.marshal writes floats with sixteen decimals; the shortest
// round-trip form reads better and parses back the same.
@(private)
user_marshalers: map[typeid]json.User_Marshaler

// The registry is process-wide state, so it lives on the plain heap
// rather than in whatever allocator the caller (or a test) is using.
@(private)
ensure_float_marshaler :: proc() {
	if json._user_marshalers == nil {
		user_marshalers = make(map[typeid]json.User_Marshaler, runtime.heap_allocator())
		json.set_user_marshalers(&user_marshalers)
	}
	_ = json.register_user_marshaler(f64, write_short_float)
}

@(private)
write_short_float :: proc(writer: io.Writer, value: any, options: ^json.Marshal_Options) -> json.Marshal_Error {
	number := (^f64)(value.data)^
	buffer: [64]byte
	text := strconv.write_float(buffer[:], number, 'g', -1, 64)
	if len(text) > 0 && text[0] == '+' {
		text = text[1:]
	}
	io.write_string(writer, text) or_return
	return nil
}
