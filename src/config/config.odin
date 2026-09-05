package config

// The typed configuration, its defaults, and the conversion to and from
// the TOML tree. Discovery and layering live in discover.odin. The
// schema is documented in doc/configuration.md; keep both in sync.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "kroken:toml"

Config :: struct {
	profile: string,
	claude:  Claude_Config,
	prompt:  Prompt_Config,
	log:     Log_Config,
}

Claude_Config :: struct {
	command:         string,
	model:           string, // "" leaves the choice to claude
	effort:          string, // "" leaves the choice to claude
	tools:           []string,
	extra_args:      []string,
	env:             []Env_Entry,
	persist_session: bool,
	max_budget_usd:  f64, // 0 means no cap
	add_git_root:    bool,
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

DEFAULT_COMMAND :: "claude"
DEFAULT_TOOLS :: []string{"Read", "Grep", "Glob"}

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
// built from and are never freed by this package.
default_config :: proc(allocator := context.allocator) -> Config {
	return Config {
		claude = Claude_Config {
			command = DEFAULT_COMMAND,
			tools = slice.clone(DEFAULT_TOOLS, allocator),
			extra_args = make([]string, 0, allocator),
			env = make([]Env_Entry, 0, allocator),
			add_git_root = true,
		},
		prompt = Prompt_Config{system = DEFAULT_SYSTEM_PROMPT, template = DEFAULT_TEMPLATE},
		log = Log_Config{enabled = true},
	}
}

destroy_config :: proc(config: ^Config, allocator := context.allocator) {
	delete(config.claude.tools, allocator)
	delete(config.claude.extra_args, allocator)
	delete(config.claude.env, allocator)
	config^ = {}
}

// Converts a merged tree into a typed config, starting from the
// defaults. Unknown keys and wrong types are errors so typos surface
// instead of being silently ignored. Strings in the result borrow from
// `root`, which must outlive the config.
from_table :: proc(root: ^toml.Table, allocator := context.allocator) -> (config: Config, message: string, ok: bool) {
	config = default_config(allocator)
	reader := Reader{allocator = allocator}
	fill_from_table(&reader, &config, root)
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
fill_from_table :: proc(reader: ^Reader, config: ^Config, root: ^toml.Table) {
	check_known_keys(reader, root, "", {"profile", "claude", "prompt", "log", "profiles"})
	read_string(reader, root, "", "profile", &config.profile)

	if claude := table_section(reader, root, "claude"); claude != nil {
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
	if prompt := table_section(reader, root, "prompt"); prompt != nil {
		check_known_keys(reader, prompt, "prompt.", {"system", "template"})
		read_string(reader, prompt, "prompt.", "system", &config.prompt.system)
		read_string(reader, prompt, "prompt.", "template", &config.prompt.template)
	}
	if log := table_section(reader, root, "log"); log != nil {
		check_known_keys(reader, log, "log.", {"enabled", "directory"})
		read_bool(reader, log, "log.", "enabled", &config.log.enabled)
		read_string(reader, log, "log.", "directory", &config.log.directory)
	}
	if !reader.failed && config.claude.command == "" {
		fail(reader, strings.clone("claude.command must not be empty", reader.allocator))
	}
}

@(private)
check_known_keys :: proc(reader: ^Reader, table: ^toml.Table, prefix: string, known: []string) {
	for key in table.keys {
		if !slice.contains(known, key) {
			fail(reader, fmt.aprintf("unknown key %s%s", prefix, key, allocator = reader.allocator))
			return
		}
	}
}

// nil when the section is absent or not a table (the latter fails).
@(private)
table_section :: proc(reader: ^Reader, root: ^toml.Table, key: string) -> ^toml.Table {
	value, present := toml.table_get(root, key)
	if !present {
		return nil
	}
	table, is_table := value.(^toml.Table)
	if !is_table {
		fail_type(reader, "", key, "a table")
		return nil
	}
	return table
}

@(private)
read_string :: proc(reader: ^Reader, table: ^toml.Table, prefix: string, key: string, destination: ^string) {
	value, present := toml.table_get(table, key)
	if !present {
		return
	}
	text, is_string := value.(string)
	if !is_string {
		fail_type(reader, prefix, key, "a string")
		return
	}
	destination^ = text
}

@(private)
read_bool :: proc(reader: ^Reader, table: ^toml.Table, prefix: string, key: string, destination: ^bool) {
	value, present := toml.table_get(table, key)
	if !present {
		return
	}
	flag, is_bool := value.(bool)
	if !is_bool {
		fail_type(reader, prefix, key, "true or false")
		return
	}
	destination^ = flag
}

@(private)
read_f64 :: proc(reader: ^Reader, table: ^toml.Table, prefix: string, key: string, destination: ^f64) {
	value, present := toml.table_get(table, key)
	if !present {
		return
	}
	#partial switch number in value {
	case f64:
		destination^ = number
	case i64:
		destination^ = f64(number)
	case:
		fail_type(reader, prefix, key, "a number")
	}
}

@(private)
read_string_list :: proc(reader: ^Reader, table: ^toml.Table, prefix: string, key: string, destination: ^[]string) {
	value, present := toml.table_get(table, key)
	if !present {
		return
	}
	array, is_array := value.(^toml.Array)
	if !is_array {
		fail_type(reader, prefix, key, "an array of strings")
		return
	}
	items := make([]string, len(array.items), reader.allocator)
	for item, index in array.items {
		text, is_string := item.(string)
		if !is_string {
			delete(items, reader.allocator)
			fail_type(reader, prefix, key, "an array of strings")
			return
		}
		items[index] = text
	}
	delete(destination^, reader.allocator)
	destination^ = items
}

@(private)
read_env :: proc(reader: ^Reader, table: ^toml.Table, prefix: string, key: string, destination: ^[]Env_Entry) {
	value, present := toml.table_get(table, key)
	if !present {
		return
	}
	env_table, is_table := value.(^toml.Table)
	if !is_table {
		fail_type(reader, prefix, key, "a table of strings")
		return
	}
	entries := make([]Env_Entry, len(env_table.keys), reader.allocator)
	for name, index in env_table.keys {
		text, is_string := env_table.values[index].(string)
		if !is_string {
			delete(entries, reader.allocator)
			fail_type(reader, prefix, key, "a table of strings")
			return
		}
		entries[index] = Env_Entry{name = name, value = text}
	}
	delete(destination^, reader.allocator)
	destination^ = entries
}

// Builds a tree holding every effective value, defaults included, for
// `kroken config`.
to_table :: proc(config: Config, allocator := context.allocator) -> ^toml.Table {
	root := toml.new_table(allocator)
	toml.table_set(root, "profile", strings.clone(config.profile, allocator), allocator)

	claude := toml.new_table(allocator)
	claude.explicit = true
	toml.table_set(claude, "command", strings.clone(config.claude.command, allocator), allocator)
	toml.table_set(claude, "model", strings.clone(config.claude.model, allocator), allocator)
	toml.table_set(claude, "effort", strings.clone(config.claude.effort, allocator), allocator)
	toml.table_set(claude, "tools", string_array(config.claude.tools, allocator), allocator)
	toml.table_set(claude, "extra_args", string_array(config.claude.extra_args, allocator), allocator)
	toml.table_set(claude, "persist_session", config.claude.persist_session, allocator)
	toml.table_set(claude, "max_budget_usd", config.claude.max_budget_usd, allocator)
	toml.table_set(claude, "add_git_root", config.claude.add_git_root, allocator)
	env := toml.new_table(allocator)
	env.explicit = true
	for entry in config.claude.env {
		toml.table_set(env, entry.name, strings.clone(entry.value, allocator), allocator)
	}
	toml.table_set(claude, "env", env, allocator)
	toml.table_set(root, "claude", claude, allocator)

	prompt := toml.new_table(allocator)
	prompt.explicit = true
	toml.table_set(prompt, "system", strings.clone(config.prompt.system, allocator), allocator)
	toml.table_set(prompt, "template", strings.clone(config.prompt.template, allocator), allocator)
	toml.table_set(root, "prompt", prompt, allocator)

	log := toml.new_table(allocator)
	log.explicit = true
	toml.table_set(log, "enabled", config.log.enabled, allocator)
	toml.table_set(log, "directory", strings.clone(config.log.directory, allocator), allocator)
	toml.table_set(root, "log", log, allocator)
	return root
}

@(private)
string_array :: proc(items: []string, allocator := context.allocator) -> ^toml.Array {
	array := toml.new_array(allocator)
	for item in items {
		append(&array.items, strings.clone(item, allocator))
	}
	return array
}
