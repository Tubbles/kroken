package backend

// The backend interface and the parts every backend shares: running a
// process with the prompt on stdin, keeping the run directory, and the
// environment merge. A backend is a name plus two procedures: `build`
// turns the configuration and prompts into a command line, and `parse`
// turns the process output into a Result. Nothing in this package
// knows which backends exist; the CLI holds the list.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "kroken:config"

Invocation :: struct {
	command:           []string, // argv, command[0] is the executable
	working_directory: string,
	env_overrides:     []config.Env_Entry,
	stdin:             string, // what the child reads on stdin; the prompt, or prompt plus instructions
}

Result :: struct {
	is_error:        bool,
	error_text:      string, // what went wrong, when is_error
	text:            string, // the final message, as text
	replacement:     string, // the structured replacement, when has_replacement
	has_replacement: bool,
	session_id:      string,
	summary:         string, // one line for the status line, e.g. "2 turns, $0.18"
}

Outcome :: struct {
	result:    Result,
	stdout:    string,
	stderr:    string,
	exit_code: int,
}

Build_Proc :: #type proc(settings: ^config.Config, system_prompt: string, user_prompt: string, working_directory: string, git_root: string, run_directory: string, allocator: runtime.Allocator) -> (invocation: Invocation, message: string, ok: bool)
Parse_Proc :: #type proc(stdout: string, exit_code: int, allocator: runtime.Allocator) -> (result: Result, message: string, ok: bool)
Set_Model_Proc :: #type proc(settings: ^config.Config, model: string)

Backend :: struct {
	name:        string,
	description: string, // one line for help text
	build:       Build_Proc,
	parse:       Parse_Proc,
	set_model:   Set_Model_Proc, // applies the --model override to this backend's section
}

find :: proc(backends: []Backend, name: string) -> (found: Backend, ok: bool) {
	for candidate in backends {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

names :: proc(backends: []Backend, allocator := context.allocator) -> string {
	parts := make([]string, len(backends), allocator)
	defer delete(parts, allocator)
	for candidate, index in backends {
		parts[index] = candidate.name
	}
	joined, _ := strings.join(parts, ", ", allocator)
	return joined
}

destroy_invocation :: proc(invocation: ^Invocation, allocator := context.allocator) {
	for argument in invocation.command {
		delete(argument, allocator)
	}
	delete(invocation.command, allocator)
	delete(invocation.stdin, allocator)
	invocation^ = {}
}

destroy_result :: proc(result: ^Result, allocator := context.allocator) {
	delete(result.error_text, allocator)
	delete(result.text, allocator)
	delete(result.replacement, allocator)
	delete(result.session_id, allocator)
	delete(result.summary, allocator)
	result^ = {}
}

destroy_outcome :: proc(outcome: ^Outcome, allocator := context.allocator) {
	destroy_result(&outcome.result, allocator)
	delete(outcome.stdout, allocator)
	delete(outcome.stderr, allocator)
	outcome^ = {}
}

// Runs the invocation and parses its output with `chosen.parse`. The
// prompt goes to the child as stdin from a file in `run_directory`,
// which sidesteps argument length limits and keeps the selection out of
// process listings; the command line, stderr, and raw stdout are kept
// there too. Returns ok=false only when the process could not be run or
// its output could not be parsed; a run the backend itself reports as
// failed comes back with ok=true and `outcome.result.is_error` set.
execute :: proc(chosen: Backend, invocation: Invocation, run_directory: string, allocator := context.allocator) -> (outcome: Outcome, message: string, ok: bool) {
	prompt_path, prompt_error := write_run_file(run_directory, "prompt.txt", invocation.stdin, allocator)
	if prompt_error != nil {
		return {}, fmt.aprintf("cannot write prompt file: %v", prompt_error, allocator = allocator), false
	}
	defer delete(prompt_path, allocator)
	write_command_log(invocation, run_directory, allocator)

	stdin_file, open_error := os.open(prompt_path, {.Read})
	if open_error != nil {
		return {}, fmt.aprintf("cannot open prompt file: %v", open_error, allocator = allocator), false
	}
	defer os.close(stdin_file)

	base_environment, _ := os.environ(allocator)
	defer delete_strings(base_environment, allocator)
	environment := merge_environment(base_environment, invocation.env_overrides, allocator)
	defer delete_strings(environment, allocator)

	description := os.Process_Desc {
		working_dir = invocation.working_directory,
		command     = invocation.command,
		env         = environment,
		stdin       = stdin_file,
	}
	state, stdout_bytes, stderr_bytes, run_error := os.process_exec(description, allocator)
	outcome.stdout = string(stdout_bytes)
	outcome.stderr = string(stderr_bytes)
	outcome.exit_code = state.exit_code
	keep_run_file(run_directory, "stderr.txt", outcome.stderr, allocator)
	keep_run_file(run_directory, "stdout.txt", outcome.stdout, allocator)
	if run_error != nil {
		message = fmt.aprintf("cannot run %s: %v", invocation.command[0], run_error, allocator = allocator)
		destroy_outcome(&outcome, allocator)
		return {}, message, false
	}

	result, parse_message, parse_ok := chosen.parse(outcome.stdout, outcome.exit_code, allocator)
	if !parse_ok {
		message = fmt.aprintf("%s (exit code %d)%s", parse_message, outcome.exit_code, stderr_excerpt(outcome.stderr, allocator), allocator = allocator)
		delete(parse_message, allocator)
		destroy_outcome(&outcome, allocator)
		return {}, message, false
	}
	outcome.result = result
	return outcome, "", true
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

// Writes `content` to `<run_directory>/<name>` and returns the path.
write_run_file :: proc(run_directory: string, name: string, content: string, allocator := context.allocator) -> (path: string, error: os.Error) {
	path = os.join_path({run_directory, name}, allocator) or_return
	error = os.write_entire_file(path, content)
	if error != nil {
		delete(path, allocator)
		return "", error
	}
	return path, nil
}

// write_run_file for callers that do not need the path back.
@(private)
keep_run_file :: proc(run_directory: string, name: string, content: string, allocator := context.allocator) {
	path, error := write_run_file(run_directory, name, content, allocator)
	if error == nil {
		delete(path, allocator)
	}
}

@(private)
delete_strings :: proc(items: []string, allocator := context.allocator) {
	for item in items {
		delete(item, allocator)
	}
	delete(items, allocator)
}

@(private)
write_command_log :: proc(invocation: Invocation, run_directory: string, allocator := context.allocator) {
	builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "working directory: ")
	strings.write_string(&builder, invocation.working_directory)
	strings.write_string(&builder, "\nenvironment overrides:")
	for entry in invocation.env_overrides {
		strings.write_string(&builder, " ")
		strings.write_string(&builder, entry.name)
	}
	strings.write_string(&builder, "\ncommand:\n")
	for argument in invocation.command {
		strings.write_string(&builder, "  ")
		strings.write_quoted_string(&builder, argument)
		strings.write_byte(&builder, '\n')
	}
	keep_run_file(run_directory, "command.txt", strings.to_string(builder), allocator)
}

@(private)
stderr_excerpt :: proc(stderr: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_space(stderr)
	if trimmed == "" {
		return ""
	}
	return fmt.aprintf(": %s", trimmed, allocator = allocator)
}
