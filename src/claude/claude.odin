package claude

// Assembles the `claude -p` command line and interprets its JSON result.
// Everything in this file is pure; process execution is in run.odin.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "kroken:config"

// Asking for structured output turns the replacement into one JSON
// string, so no markdown fences or explanations need to be stripped.
REPLACEMENT_SCHEMA :: `{"type":"object","properties":{"replacement":{"type":"string","description":"The text that replaces the selection, verbatim."}},"required":["replacement"],"additionalProperties":false}`

Invocation :: struct {
	command:           []string, // argv, command[0] is the executable
	working_directory: string,
	env_overrides:     []config.Env_Entry,
}

// `git_root` may be empty. The working directory is the target file's
// directory so Claude Code picks up the CLAUDE.md hierarchy; --bare is
// never passed for the same reason.
build_invocation :: proc(claude_config: config.Claude_Config, system_prompt: string, working_directory: string, git_root: string, allocator := context.allocator) -> Invocation {
	command := make([dynamic]string, allocator)
	append(&command, claude_config.command)
	append(&command, "-p")
	append(&command, "--output-format", "json")
	append(&command, "--json-schema", REPLACEMENT_SCHEMA)
	if system_prompt != "" {
		append(&command, "--append-system-prompt", system_prompt)
	}
	tools, _ := strings.join(claude_config.tools, ",", allocator)
	append(&command, "--tools", tools)
	if claude_config.model != "" {
		append(&command, "--model", claude_config.model)
	}
	if claude_config.effort != "" {
		append(&command, "--effort", claude_config.effort)
	}
	if !claude_config.persist_session {
		append(&command, "--no-session-persistence")
	}
	if claude_config.add_git_root && git_root != "" && git_root != working_directory {
		append(&command, "--add-dir", git_root)
	}
	if claude_config.max_budget_usd > 0 {
		append(&command, "--max-budget-usd", fmt.aprintf("%.2f", claude_config.max_budget_usd, allocator = allocator))
	}
	append(&command, ..claude_config.extra_args)
	return Invocation{command = command[:], working_directory = working_directory, env_overrides = claude_config.env}
}

// Frees only what build_invocation allocated; the config strings it
// points into belong to the caller.
destroy_invocation :: proc(invocation: ^Invocation, allocator := context.allocator) {
	for argument, index in invocation.command {
		if index > 0 && invocation.command[index - 1] == "--tools" {
			delete(argument, allocator)
		}
		if index > 0 && invocation.command[index - 1] == "--max-budget-usd" {
			delete(argument, allocator)
		}
	}
	delete(invocation.command, allocator)
	invocation^ = {}
}

// Applies overrides on top of a `KEY=VALUE` environment list, replacing
// existing keys in place and appending new ones.
merge_environment :: proc(base: []string, overrides: []config.Env_Entry, allocator := context.allocator) -> []string {
	merged := make([dynamic]string, allocator)
	for entry in base {
		append(&merged, strings.clone(entry, allocator))
	}
	for override in overrides {
		assignment := strings.concatenate({override.name, "=", override.value}, allocator)
		replaced := false
		for entry, index in merged {
			if strings.has_prefix(entry, override.name) && len(entry) > len(override.name) && entry[len(override.name)] == '=' {
				delete(entry, allocator)
				merged[index] = assignment
				replaced = true
				break
			}
		}
		if !replaced {
			append(&merged, assignment)
		}
	}
	return merged[:]
}

Result :: struct {
	is_error:        bool,
	subtype:         string,
	text:            string, // the `result` field: the answer, or the error text
	replacement:     string, // structured_output.replacement
	has_replacement: bool,
	session_id:      string,
	total_cost_usd:  f64,
	duration_ms:     i64,
	num_turns:       i64,
}

destroy_result :: proc(result: ^Result, allocator := context.allocator) {
	delete(result.subtype, allocator)
	delete(result.text, allocator)
	delete(result.replacement, allocator)
	delete(result.session_id, allocator)
	result^ = {}
}

// Reads the single JSON object `claude -p --output-format json` prints.
parse_result :: proc(output: string, allocator := context.allocator) -> (result: Result, message: string, ok: bool) {
	value, error := json.parse_string(output, .JSON, parse_integers = true, allocator = allocator)
	if error != .None {
		return {}, fmt.aprintf("claude output is not valid JSON (%v)", error, allocator = allocator), false
	}
	defer json.destroy_value(value, allocator)
	object, is_object := value.(json.Object)
	if !is_object {
		return {}, strings.clone("claude output is not a JSON object", allocator), false
	}
	result.is_error = bool_field(object, "is_error")
	result.subtype = string_field(object, "subtype", allocator)
	result.text = string_field(object, "result", allocator)
	result.session_id = string_field(object, "session_id", allocator)
	result.total_cost_usd = number_field(object, "total_cost_usd")
	result.duration_ms = i64(number_field(object, "duration_ms"))
	result.num_turns = i64(number_field(object, "num_turns"))
	if structured, has_structured := object["structured_output"].(json.Object); has_structured {
		if replacement, has_replacement := structured["replacement"].(json.String); has_replacement {
			result.replacement = strings.clone(replacement, allocator)
			result.has_replacement = true
		}
	}
	return result, "", true
}

@(private)
string_field :: proc(object: json.Object, key: string, allocator := context.allocator) -> string {
	text, is_string := object[key].(json.String)
	if !is_string {
		return ""
	}
	return strings.clone(text, allocator)
}

@(private)
bool_field :: proc(object: json.Object, key: string) -> bool {
	flag, is_bool := object[key].(json.Boolean)
	return is_bool && bool(flag)
}

@(private)
number_field :: proc(object: json.Object, key: string) -> f64 {
	#partial switch number in object[key] {
	case json.Integer:
		return f64(number)
	case json.Float:
		return f64(number)
	}
	return 0
}
