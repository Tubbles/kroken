package claude

import "core:slice"
import "core:strings"
import "core:testing"
import "kroken:config"

@(test)
builds_the_expected_command_line :: proc(t: ^testing.T) {
	claude_config := config.default_config()
	defer config.destroy_config(&claude_config)
	claude_config.claude.model = "opus"
	claude_config.claude.effort = "high"
	claude_config.claude.max_budget_usd = 1.5
	extra := []string{"--verbose"}
	claude_config.claude.extra_args = slice.clone(extra)

	invocation := build_invocation(claude_config.claude, "SYSTEM", "/repo/src", "/repo")
	defer destroy_invocation(&invocation)

	joined, _ := strings.join(invocation.command, " ")
	defer delete(joined)
	testing.expect_value(t, joined, "claude -p --output-format json --json-schema " + REPLACEMENT_SCHEMA + " --append-system-prompt SYSTEM --tools Read,Grep,Glob --model opus --effort high --no-session-persistence --add-dir /repo --max-budget-usd 1.50 --verbose")
	testing.expect_value(t, invocation.working_directory, "/repo/src")
}

@(test)
omits_optional_flags :: proc(t: ^testing.T) {
	claude_config := config.default_config()
	defer config.destroy_config(&claude_config)
	claude_config.claude.persist_session = true
	delete(claude_config.claude.tools)
	claude_config.claude.tools = make([]string, 0)

	invocation := build_invocation(claude_config.claude, "", "/repo", "/repo")
	defer destroy_invocation(&invocation)

	joined, _ := strings.join(invocation.command, " ")
	defer delete(joined)
	testing.expect_value(t, joined, "claude -p --output-format json --json-schema " + REPLACEMENT_SCHEMA + " --tools ")
	testing.expect(t, !slice.contains(invocation.command, "--bare"))
}

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

@(private = "file")
SUCCESS_OUTPUT :: `{"type":"result","subtype":"success","is_error":false,"duration_ms":4213,"num_turns":3,"result":"done","session_id":"abc-123","total_cost_usd":0.0421,"structured_output":{"replacement":"int add(int a, int b) {\n\treturn a + b;\n}"}}`

@(test)
parses_a_successful_result :: proc(t: ^testing.T) {
	result, message, ok := parse_result(SUCCESS_OUTPUT)
	defer delete(message)
	testing.expectf(t, ok, "parse failed: %s", message)
	if !ok {
		return
	}
	defer destroy_result(&result)
	testing.expect_value(t, result.is_error, false)
	testing.expect_value(t, result.subtype, "success")
	testing.expect_value(t, result.has_replacement, true)
	testing.expect_value(t, result.replacement, "int add(int a, int b) {\n\treturn a + b;\n}")
	testing.expect_value(t, result.session_id, "abc-123")
	testing.expect_value(t, result.total_cost_usd, 0.0421)
	testing.expect_value(t, result.duration_ms, 4213)
	testing.expect_value(t, result.num_turns, 3)
}

@(test)
parses_an_error_result_and_rejects_garbage :: proc(t: ^testing.T) {
	result, message, ok := parse_result(`{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in","duration_ms":10.0}`)
	defer delete(message)
	testing.expect(t, ok)
	defer destroy_result(&result)
	testing.expect_value(t, result.is_error, true)
	testing.expect_value(t, result.text, "Not logged in")
	testing.expect_value(t, result.has_replacement, false)
	testing.expect_value(t, result.duration_ms, 10)

	_, garbage_message, garbage_ok := parse_result("Fatal: something\n")
	defer delete(garbage_message)
	testing.expect_value(t, garbage_ok, false)
	testing.expect(t, strings.has_prefix(garbage_message, "claude output is not valid JSON"))

	_, array_message, array_ok := parse_result("[1]")
	defer delete(array_message)
	testing.expect_value(t, array_ok, false)
	testing.expect_value(t, array_message, "claude output is not a JSON object")
}

// `cat` echoes its stdin, so feeding a result document as the prompt
// exercises the stdin file, the process, and the parser together.
@(test)
runs_a_process_with_the_prompt_on_stdin :: proc(t: ^testing.T) {
	command := []string{"cat"}
	invocation := Invocation{command = command, working_directory = "/"}
	outcome, message, ok := run(invocation, SUCCESS_OUTPUT, "")
	defer delete(message)
	testing.expectf(t, ok, "run failed: %s", message)
	if !ok {
		return
	}
	defer destroy_outcome(&outcome)
	testing.expect_value(t, outcome.exit_code, 0)
	testing.expect_value(t, outcome.stdout, SUCCESS_OUTPUT)
	testing.expect_value(t, outcome.result.session_id, "abc-123")
}

@(test)
reports_a_missing_executable :: proc(t: ^testing.T) {
	command := []string{"/nonexistent/kroken-test-binary"}
	invocation := Invocation{command = command, working_directory = "/"}
	_, message, ok := run(invocation, "prompt", "")
	defer delete(message)
	testing.expect_value(t, ok, false)
	testing.expect(t, strings.has_prefix(message, "cannot run /nonexistent/kroken-test-binary"))
}
