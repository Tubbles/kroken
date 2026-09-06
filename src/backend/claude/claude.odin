package claude

// Claude Code backend: `claude -p` with structured output. The working
// directory is the target file's directory so Claude Code picks up the
// CLAUDE.md hierarchy; --bare is never passed for the same reason.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "kroken:backend"
import "kroken:config"

// Asking for structured output turns the replacement into one JSON
// string, so no markdown fences or explanations need to be stripped.
REPLACEMENT_SCHEMA :: `{"type":"object","properties":{"replacement":{"type":"string","description":"The text that replaces the selection, verbatim."}},"required":["replacement"],"additionalProperties":false}`

definition :: proc() -> backend.Backend {
	return backend.Backend {
		name        = "claude",
		description = "Claude Code, `claude -p` (any Anthropic login or provider claude supports)",
		build       = build,
		parse       = parse,
		set_model   = set_model,
	}
}

set_model :: proc(settings: ^config.Config, model: string) {
	settings.claude.model = model
}

// Every argument is cloned so the invocation owns its command line.
build :: proc(settings: ^config.Config, system_prompt: string, user_prompt: string, working_directory: string, git_root: string, run_directory: string, allocator: runtime.Allocator) -> (invocation: backend.Invocation, message: string, ok: bool) {
	claude_config := settings.claude
	command := make([dynamic]string, allocator)
	add :: proc(command: ^[dynamic]string, allocator: runtime.Allocator, arguments: ..string) {
		for argument in arguments {
			append(command, strings.clone(argument, allocator))
		}
	}
	add(&command, allocator, claude_config.command, "-p")
	add(&command, allocator, "--output-format", "json")
	add(&command, allocator, "--json-schema", REPLACEMENT_SCHEMA)
	if system_prompt != "" {
		add(&command, allocator, "--append-system-prompt", system_prompt)
	}
	tools, _ := strings.join(claude_config.tools, ",", allocator)
	add(&command, allocator, "--tools")
	append(&command, tools)
	if claude_config.model != "" {
		add(&command, allocator, "--model", claude_config.model)
	}
	if claude_config.effort != "" {
		add(&command, allocator, "--effort", claude_config.effort)
	}
	if !claude_config.persist_session {
		add(&command, allocator, "--no-session-persistence")
	}
	if claude_config.add_git_root && git_root != "" && git_root != working_directory {
		add(&command, allocator, "--add-dir", git_root)
	}
	if claude_config.max_budget_usd > 0 {
		add(&command, allocator, "--max-budget-usd")
		append(&command, fmt.aprintf("%.2f", claude_config.max_budget_usd, allocator = allocator))
	}
	add(&command, allocator, ..claude_config.extra_args)
	invocation = backend.Invocation {
		command           = command[:],
		working_directory = working_directory,
		env_overrides     = claude_config.env,
		stdin             = strings.clone(user_prompt, allocator),
	}
	return invocation, "", true
}

// Reads the single JSON object `claude -p --output-format json` prints.
parse :: proc(stdout: string, exit_code: int, allocator: runtime.Allocator) -> (result: backend.Result, message: string, ok: bool) {
	value, error := json.parse_string(stdout, .JSON, parse_integers = true, allocator = allocator)
	if error != .None {
		return {}, fmt.aprintf("claude output is not valid JSON (%v)", error, allocator = allocator), false
	}
	defer json.destroy_value(value, allocator)
	object, is_object := value.(json.Object)
	if !is_object {
		return {}, strings.clone("claude output is not a JSON object", allocator), false
	}
	result.is_error = bool_field(object, "is_error")
	result.text = string_field(object, "result", allocator)
	result.session_id = string_field(object, "session_id", allocator)
	if result.is_error {
		subtype := string_field(object, "subtype", allocator)
		defer delete(subtype, allocator)
		result.error_text = fmt.aprintf("%s: %s", subtype, strings.trim_space(result.text), allocator = allocator)
	}
	if structured, has_structured := object["structured_output"].(json.Object); has_structured {
		if replacement, has_replacement := structured["replacement"].(json.String); has_replacement {
			result.replacement = strings.clone(string(replacement), allocator)
			result.has_replacement = true
		}
	}
	result.summary = fmt.aprintf("%d turns, $%.4f", i64(number_field(object, "num_turns")), number_field(object, "total_cost_usd"), allocator = allocator)
	return result, "", true
}

@(private)
string_field :: proc(object: json.Object, key: string, allocator := context.allocator) -> string {
	text, is_string := object[key].(json.String)
	if !is_string {
		return ""
	}
	return strings.clone(string(text), allocator)
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
