package backend

import "core:os"
import "core:strings"
import "core:testing"
import "kroken:config"

@(test)
merges_environment_overrides :: proc(t: ^testing.T) {
	base := []string{"HOME=/home/me", "PATH=/bin", "HOMEBREW=x"}
	overrides := []config.Env_Entry{{"HOME", "/other"}, {"CLAUDE_CONFIG_DIR", "/cfg"}}
	merged := merge_environment(base, overrides)
	defer {
		for entry in merged {
			delete(entry)
		}
		delete(merged)
	}
	testing.expect_value(t, len(merged), 4)
	testing.expect_value(t, merged[0], "HOME=/other")
	testing.expect_value(t, merged[1], "PATH=/bin")
	testing.expect_value(t, merged[2], "HOMEBREW=x")
	testing.expect_value(t, merged[3], "CLAUDE_CONFIG_DIR=/cfg")
}

@(test)
finds_backends_by_name :: proc(t: ^testing.T) {
	backends := []Backend{{name = "one"}, {name = "two"}}
	found, ok := find(backends, "two")
	testing.expect(t, ok)
	testing.expect_value(t, found.name, "two")
	_, missing := find(backends, "three")
	testing.expect_value(t, missing, false)
	joined := names(backends)
	defer delete(joined)
	testing.expect_value(t, joined, "one, two")
}

// A backend whose parse copies stdout into the result text.
@(private = "file")
echo_parse :: proc(stdout: string, exit_code: int, allocator := context.allocator) -> (result: Result, message: string, ok: bool) {
	if exit_code != 0 {
		return {}, strings.clone("nonzero exit", allocator), false
	}
	result.text = strings.clone(stdout, allocator)
	result.summary = strings.clone("echoed", allocator)
	return result, "", true
}

// `cat` echoes its stdin, so this covers the prompt file, environment
// merge, process wait, run files, and the parse hook together.
@(test)
executes_a_process_with_the_prompt_on_stdin :: proc(t: ^testing.T) {
	run_directory, directory_error := os.make_directory_temp("", "kroken-backend-test-*", context.allocator)
	testing.expect_value(t, directory_error, nil)
	defer delete(run_directory)
	defer os.remove_all(run_directory)

	command := []string{"cat"}
	invocation := Invocation{command = command, working_directory = "/", stdin = "hello from stdin"}
	echo := Backend{name = "echo", parse = echo_parse}
	outcome, message, ok := execute(echo, invocation, run_directory)
	defer delete(message)
	testing.expectf(t, ok, "execute failed: %s", message)
	if !ok {
		return
	}
	defer destroy_outcome(&outcome)
	testing.expect_value(t, outcome.exit_code, 0)
	testing.expect_value(t, outcome.result.text, "hello from stdin")

	prompt_path, _ := os.join_path({run_directory, "prompt.txt"}, context.allocator)
	defer delete(prompt_path)
	testing.expect(t, os.is_file(prompt_path))
	stdout_path, _ := os.join_path({run_directory, "stdout.txt"}, context.allocator)
	defer delete(stdout_path)
	testing.expect(t, os.is_file(stdout_path))
}

@(test)
reports_a_missing_executable :: proc(t: ^testing.T) {
	run_directory, _ := os.make_directory_temp("", "kroken-backend-test-*", context.allocator)
	defer delete(run_directory)
	defer os.remove_all(run_directory)

	command := []string{"/nonexistent/kroken-test-binary"}
	invocation := Invocation{command = command, working_directory = "/", stdin = "prompt"}
	echo := Backend{name = "echo", parse = echo_parse}
	_, message, ok := execute(echo, invocation, run_directory)
	defer delete(message)
	testing.expect_value(t, ok, false)
	testing.expect(t, strings.has_prefix(message, "cannot run /nonexistent/kroken-test-binary"))
}
