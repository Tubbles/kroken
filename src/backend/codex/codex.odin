package codex

// OpenAI Codex CLI backend: `codex exec --json` with an output schema.
// Codex has no system prompt flag in exec mode, so the instructions are
// prepended to the prompt. The sandbox stays read-only by default, and
// --skip-git-repo-check lets it run for files outside a repository.
// Codex reads its own instruction files (AGENTS.md) from the project
// root down to the working directory, the same way Claude Code reads
// CLAUDE.md, which is why the working directory is the file's.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "kroken:backend"
import "kroken:config"

REPLACEMENT_SCHEMA :: `{"type":"object","properties":{"replacement":{"type":"string","description":"The text that replaces the selection, verbatim."}},"required":["replacement"],"additionalProperties":false}`

definition :: proc() -> backend.Backend {
	return backend.Backend {
		name        = "codex",
		description = "OpenAI Codex CLI, `codex exec` (ChatGPT login or OPENAI_API_KEY)",
		build       = build,
		parse       = parse,
		set_model   = set_model,
	}
}

set_model :: proc(settings: ^config.Config, model: string) {
	settings.codex.model = model
}

build :: proc(settings: ^config.Config, system_prompt: string, user_prompt: string, working_directory: string, git_root: string, run_directory: string, allocator: runtime.Allocator) -> (invocation: backend.Invocation, message: string, ok: bool) {
	codex_config := settings.codex
	schema_path, schema_error := backend.write_run_file(run_directory, "schema.json", REPLACEMENT_SCHEMA, allocator)
	if schema_error != nil {
		return {}, fmt.aprintf("cannot write the output schema: %v", schema_error, allocator = allocator), false
	}
	command := make([dynamic]string, allocator)
	add :: proc(command: ^[dynamic]string, allocator: runtime.Allocator, arguments: ..string) {
		for argument in arguments {
			append(command, strings.clone(argument, allocator))
		}
	}
	add(&command, allocator, codex_config.command, "exec", "--json", "--color", "never")
	add(&command, allocator, "--sandbox", codex_config.sandbox)
	add(&command, allocator, "--output-schema")
	append(&command, schema_path)
	if codex_config.model != "" {
		add(&command, allocator, "--model", codex_config.model)
	}
	if codex_config.effort != "" {
		add(&command, allocator, "-c")
		append(&command, fmt.aprintf("model_reasoning_effort=%q", codex_config.effort, allocator = allocator))
	}
	if !codex_config.persist_session {
		add(&command, allocator, "--ephemeral")
	}
	if codex_config.skip_git_repo_check {
		add(&command, allocator, "--skip-git-repo-check")
	}
	add(&command, allocator, ..codex_config.extra_args)
	// "-" reads the prompt from stdin; it must come after every flag.
	add(&command, allocator, "-")

	stdin: string
	if system_prompt == "" {
		stdin = strings.clone(user_prompt, allocator)
	} else {
		stdin = strings.concatenate({system_prompt, "\n\n", user_prompt}, allocator)
	}
	invocation = backend.Invocation {
		command           = command[:],
		working_directory = working_directory,
		env_overrides     = codex_config.env,
		stdin             = stdin,
	}
	return invocation, "", true
}

// Reads the JSON Lines stream of `codex exec --json`: the last completed
// agent message is the answer (JSON matching the schema), turn.completed
// carries token usage, and turn.failed or error events carry failures.
parse :: proc(stdout: string, exit_code: int, allocator: runtime.Allocator) -> (result: backend.Result, message: string, ok: bool) {
	event_count := 0
	input_tokens, output_tokens: i64
	remaining := stdout
	for line in strings.split_lines_iterator(&remaining) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		value, error := json.parse_string(trimmed, .JSON, parse_integers = true, allocator = allocator)
		if error != .None {
			continue
		}
		defer json.destroy_value(value, allocator)
		event, is_object := value.(json.Object)
		if !is_object {
			continue
		}
		event_count += 1
		switch string_of(event["type"]) {
		case "thread.started":
			replace(&result.session_id, string_of(event["thread_id"]), allocator)
		case "item.completed":
			if item, has_item := event["item"].(json.Object); has_item && string_of(item["type"]) == "agent_message" {
				replace(&result.text, string_of(item["text"]), allocator)
			}
		case "turn.completed":
			if usage, has_usage := event["usage"].(json.Object); has_usage {
				input_tokens += integer_of(usage["input_tokens"])
				output_tokens += integer_of(usage["output_tokens"])
			}
		case "turn.failed":
			result.is_error = true
			if failure, has_failure := event["error"].(json.Object); has_failure {
				replace(&result.error_text, string_of(failure["message"]), allocator)
			}
		case "error":
			result.is_error = true
			replace(&result.error_text, string_of(event["message"]), allocator)
		}
	}
	if event_count == 0 {
		backend.destroy_result(&result, allocator)
		return {}, strings.clone("codex produced no JSON events", allocator), false
	}
	if exit_code != 0 && !result.is_error {
		result.is_error = true
		replace(&result.error_text, fmt.tprintf("codex exited with code %d", exit_code), allocator)
	}
	if result.error_text == "" && result.is_error {
		result.error_text = strings.clone("turn failed", allocator)
	}
	extract_replacement(&result, allocator)
	result.summary = fmt.aprintf("%d input tokens, %d output tokens", input_tokens, output_tokens, allocator = allocator)
	return result, "", true
}

// The final message should be the schema-shaped JSON object.
@(private)
extract_replacement :: proc(result: ^backend.Result, allocator: runtime.Allocator) {
	if result.text == "" {
		return
	}
	value, error := json.parse_string(result.text, .JSON, allocator = allocator)
	if error != .None {
		return
	}
	defer json.destroy_value(value, allocator)
	object, is_object := value.(json.Object)
	if !is_object {
		return
	}
	if replacement, has_replacement := object["replacement"].(json.String); has_replacement {
		result.replacement = strings.clone(string(replacement), allocator)
		result.has_replacement = true
	}
}

@(private)
replace :: proc(destination: ^string, text: string, allocator: runtime.Allocator) {
	delete(destination^, allocator)
	destination^ = strings.clone(text, allocator)
}

@(private)
string_of :: proc(value: json.Value) -> string {
	text, is_string := value.(json.String)
	return is_string ? string(text) : ""
}

@(private)
integer_of :: proc(value: json.Value) -> i64 {
	#partial switch number in value {
	case json.Integer:
		return i64(number)
	case json.Float:
		return i64(number)
	}
	return 0
}
