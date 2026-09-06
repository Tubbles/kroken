package claude

import "core:slice"
import "core:strings"
import "core:testing"
import "kroken:backend"
import "kroken:config"

@(test)
builds_the_expected_command_line :: proc(t: ^testing.T) {
	settings := config.default_config()
	defer config.destroy_config(&settings)
	settings.claude.model = "opus"
	settings.claude.effort = "high"
	settings.claude.max_budget_usd = 1.5
	extra := []string{"--verbose"}
	settings.claude.extra_args = slice.clone(extra)

	invocation, message, ok := build(&settings, "SYSTEM", "PROMPT", "/repo/src", "/repo", "/run", context.allocator)
	defer delete(message)
	testing.expect(t, ok)
	defer backend.destroy_invocation(&invocation)

	joined, _ := strings.join(invocation.command, " ")
	defer delete(joined)
	testing.expect_value(t, joined, "claude -p --output-format json --json-schema " + REPLACEMENT_SCHEMA + " --append-system-prompt SYSTEM --tools Read,Grep,Glob --model opus --effort high --no-session-persistence --add-dir /repo --max-budget-usd 1.50 --verbose")
	testing.expect_value(t, invocation.working_directory, "/repo/src")
	testing.expect_value(t, invocation.stdin, "PROMPT")
}

@(test)
omits_optional_flags :: proc(t: ^testing.T) {
	settings := config.default_config()
	defer config.destroy_config(&settings)
	settings.claude.persist_session = true
	delete(settings.claude.tools)
	settings.claude.tools = make([]string, 0)

	invocation, _, _ := build(&settings, "", "PROMPT", "/repo", "/repo", "/run", context.allocator)
	defer backend.destroy_invocation(&invocation)

	joined, _ := strings.join(invocation.command, " ")
	defer delete(joined)
	testing.expect_value(t, joined, "claude -p --output-format json --json-schema " + REPLACEMENT_SCHEMA + " --tools ")
	testing.expect(t, !slice.contains(invocation.command, "--bare"))
}

@(private = "file")
SUCCESS_OUTPUT :: `{"type":"result","subtype":"success","is_error":false,"duration_ms":4213,"num_turns":3,"result":"done","session_id":"abc-123","total_cost_usd":0.0421,"structured_output":{"replacement":"int add(int a, int b) {\n\treturn a + b;\n}"}}`

@(test)
parses_a_successful_result :: proc(t: ^testing.T) {
	result, message, ok := parse(SUCCESS_OUTPUT, 0, context.allocator)
	defer delete(message)
	testing.expectf(t, ok, "parse failed: %s", message)
	if !ok {
		return
	}
	defer backend.destroy_result(&result)
	testing.expect_value(t, result.is_error, false)
	testing.expect_value(t, result.has_replacement, true)
	testing.expect_value(t, result.replacement, "int add(int a, int b) {\n\treturn a + b;\n}")
	testing.expect_value(t, result.session_id, "abc-123")
	testing.expect_value(t, result.summary, "3 turns, $0.0421")
}

@(test)
parses_an_error_result_and_rejects_garbage :: proc(t: ^testing.T) {
	result, message, ok := parse(`{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in\n","duration_ms":10.0}`, 1, context.allocator)
	defer delete(message)
	testing.expect(t, ok)
	defer backend.destroy_result(&result)
	testing.expect_value(t, result.is_error, true)
	testing.expect_value(t, result.error_text, "error_during_execution: Not logged in")
	testing.expect_value(t, result.has_replacement, false)

	_, garbage_message, garbage_ok := parse("Fatal: something\n", 1, context.allocator)
	defer delete(garbage_message)
	testing.expect_value(t, garbage_ok, false)
	testing.expect(t, strings.has_prefix(garbage_message, "claude output is not valid JSON"))

	_, array_message, array_ok := parse("[1]", 0, context.allocator)
	defer delete(array_message)
	testing.expect_value(t, array_ok, false)
	testing.expect_value(t, array_message, "claude output is not a JSON object")
}
