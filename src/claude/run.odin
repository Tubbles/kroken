package claude

// Runs an invocation. The prompt is handed to the child on stdin from a
// file, which sidesteps argument length limits and keeps the selection
// out of process listings. When `log_directory` is set the prompt, the
// command line, stderr, and the raw result are kept there.

import "core:fmt"
import "core:os"
import "core:strings"

Outcome :: struct {
	result:    Result,
	stdout:    string,
	stderr:    string,
	exit_code: int,
}

destroy_outcome :: proc(outcome: ^Outcome, allocator := context.allocator) {
	destroy_result(&outcome.result, allocator)
	delete(outcome.stdout, allocator)
	delete(outcome.stderr, allocator)
	outcome^ = {}
}

// Returns ok=false only when the process could not be run or its output
// could not be parsed; a run that claude itself reports as failed comes
// back with ok=true and `outcome.result.is_error` set.
run :: proc(invocation: Invocation, prompt: string, log_directory: string, allocator := context.allocator) -> (outcome: Outcome, message: string, ok: bool) {
	prompt_path, prompt_error := write_prompt_file(prompt, log_directory, allocator)
	if prompt_error != nil {
		return {}, fmt.aprintf("cannot write prompt file: %v", prompt_error, allocator = allocator), false
	}
	defer {
		if log_directory == "" {
			_ = os.remove(prompt_path)
		}
		delete(prompt_path, allocator)
	}
	if log_directory != "" {
		write_command_log(invocation, log_directory, allocator)
	}

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
	if log_directory != "" {
		write_output_log(outcome, log_directory, allocator)
	}
	if run_error != nil {
		message = fmt.aprintf("cannot run %s: %v", invocation.command[0], run_error, allocator = allocator)
		destroy_outcome(&outcome, allocator)
		return {}, message, false
	}

	result, parse_message, parse_ok := parse_result(outcome.stdout, allocator)
	if !parse_ok {
		message = fmt.aprintf("%s (exit code %d)%s", parse_message, outcome.exit_code, stderr_excerpt(outcome.stderr, allocator), allocator = allocator)
		delete(parse_message, allocator)
		destroy_outcome(&outcome, allocator)
		return {}, message, false
	}
	outcome.result = result
	return outcome, "", true
}

@(private)
delete_strings :: proc(items: []string, allocator := context.allocator) {
	for item in items {
		delete(item, allocator)
	}
	delete(items, allocator)
}

@(private)
write_prompt_file :: proc(prompt: string, log_directory: string, allocator := context.allocator) -> (path: string, error: os.Error) {
	if log_directory != "" {
		path = os.join_path({log_directory, "prompt.txt"}, allocator) or_return
		error = os.write_entire_file(path, prompt)
		if error != nil {
			delete(path, allocator)
			return "", error
		}
		return path, nil
	}
	file := os.create_temp_file("", "kroken-prompt-*.txt") or_return
	name := strings.clone(os.name(file), allocator)
	_, error = os.write_string(file, prompt)
	os.close(file)
	if error != nil {
		_ = os.remove(name)
		delete(name, allocator)
		return "", error
	}
	return name, nil
}

@(private)
write_command_log :: proc(invocation: Invocation, log_directory: string, allocator := context.allocator) {
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
	write_log_file(log_directory, "command.txt", strings.to_string(builder), allocator)
}

@(private)
write_output_log :: proc(outcome: Outcome, log_directory: string, allocator := context.allocator) {
	write_log_file(log_directory, "stderr.txt", outcome.stderr, allocator)
	write_log_file(log_directory, "result.json", outcome.stdout, allocator)
}

@(private)
write_log_file :: proc(log_directory: string, name: string, content: string, allocator := context.allocator) {
	path, join_error := os.join_path({log_directory, name}, allocator)
	if join_error != nil {
		return
	}
	defer delete(path, allocator)
	_ = os.write_entire_file(path, content)
}

@(private)
stderr_excerpt :: proc(stderr: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_space(stderr)
	if trimmed == "" {
		return ""
	}
	return fmt.aprintf(": %s", trimmed, allocator = allocator)
}
