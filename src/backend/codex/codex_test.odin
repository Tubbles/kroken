package codex

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "kroken:backend"
import "kroken:config"

@(test)
builds_the_expected_command_line :: proc(t: ^testing.T) {
	run_directory, _ := os.make_directory_temp("", "kroken-codex-test-*", context.allocator)
	defer delete(run_directory)
	defer os.remove_all(run_directory)

	settings := config.default_config()
	defer config.destroy_config(&settings)
	settings.codex.model = "gpt-5.5"
	settings.codex.effort = "high"

	invocation, message, ok := build(&settings, "SYSTEM", "PROMPT", "/repo/src", "/repo", run_directory, context.allocator)
	defer delete(message)
	testing.expectf(t, ok, "build failed: %s", message)
	if !ok {
		return
	}
	defer backend.destroy_invocation(&invocation)

	schema_path, _ := os.join_path({run_directory, "schema.json"}, context.allocator)
	defer delete(schema_path)
	joined, _ := strings.join(invocation.command, " ")
	defer delete(joined)
	expected := fmt.tprintf("codex exec --json --color never --sandbox read-only --output-schema %s --model gpt-5.5 -c model_reasoning_effort=\"high\" --ephemeral --skip-git-repo-check -", schema_path)
	testing.expect_value(t, joined, expected)
	testing.expect_value(t, invocation.stdin, "SYSTEM\n\nPROMPT")
	testing.expect(t, os.is_file(schema_path))
	schema, _ := os.read_entire_file_from_path(schema_path, context.allocator)
	defer delete(schema)
	testing.expect_value(t, string(schema), REPLACEMENT_SCHEMA)
}

@(test)
omits_optional_flags :: proc(t: ^testing.T) {
	run_directory, _ := os.make_directory_temp("", "kroken-codex-test-*", context.allocator)
	defer delete(run_directory)
	defer os.remove_all(run_directory)

	settings := config.default_config()
	defer config.destroy_config(&settings)
	settings.codex.persist_session = true
	settings.codex.skip_git_repo_check = false

	invocation, _, _ := build(&settings, "", "PROMPT", "/repo", "", run_directory, context.allocator)
	defer backend.destroy_invocation(&invocation)
	joined, _ := strings.join(invocation.command, " ")
	defer delete(joined)
	testing.expect(t, !strings.contains(joined, "--ephemeral"))
	testing.expect(t, !strings.contains(joined, "--skip-git-repo-check"))
	testing.expect(t, !strings.contains(joined, "--model"))
	testing.expect(t, strings.has_suffix(joined, " -"))
	testing.expect_value(t, invocation.stdin, "PROMPT")
}

@(private = "file")
SUCCESS_STREAM :: `{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
{"type":"turn.started"}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"completed","exit_code":0}}
{"type":"item.completed","item":{"id":"item_2","type":"reasoning","text":"thinking"}}
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"{\"replacement\":\"int add(int a, int b) {\\n\\treturn a + b;\\n}\"}"}}
{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}
`

@(test)
parses_a_successful_stream :: proc(t: ^testing.T) {
	result, message, ok := parse(SUCCESS_STREAM, 0, context.allocator)
	defer delete(message)
	testing.expectf(t, ok, "parse failed: %s", message)
	if !ok {
		return
	}
	defer backend.destroy_result(&result)
	testing.expect_value(t, result.is_error, false)
	testing.expect_value(t, result.session_id, "0199a213-81c0-7800-8aa1-bbab2a035a53")
	testing.expect_value(t, result.has_replacement, true)
	testing.expect_value(t, result.replacement, "int add(int a, int b) {\n\treturn a + b;\n}")
	testing.expect_value(t, result.summary, "24763 input tokens, 122 output tokens")
}

@(test)
parses_failures :: proc(t: ^testing.T) {
	failed, _, failed_ok := parse(`{"type":"thread.started","thread_id":"t"}
{"type":"turn.failed","error":{"message":"rate limited"}}
`, 1, context.allocator)
	testing.expect(t, failed_ok)
	defer backend.destroy_result(&failed)
	testing.expect_value(t, failed.is_error, true)
	testing.expect_value(t, failed.error_text, "rate limited")

	plain, _, plain_ok := parse(`{"type":"item.completed","item":{"type":"agent_message","text":"not json at all"}}
`, 0, context.allocator)
	testing.expect(t, plain_ok)
	defer backend.destroy_result(&plain)
	testing.expect_value(t, plain.has_replacement, false)
	testing.expect_value(t, plain.text, "not json at all")

	exited, _, exited_ok := parse(`{"type":"turn.started"}
`, 2, context.allocator)
	testing.expect(t, exited_ok)
	defer backend.destroy_result(&exited)
	testing.expect_value(t, exited.is_error, true)
	testing.expect_value(t, exited.error_text, "codex exited with code 2")

	_, empty_message, empty_ok := parse("Error: not logged in\n", 1, context.allocator)
	defer delete(empty_message)
	testing.expect_value(t, empty_ok, false)
	testing.expect_value(t, empty_message, "codex produced no JSON events")
}
