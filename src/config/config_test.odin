package config

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Fixture :: struct {
	root:        string,
	environment: Environment,
	project:     string, // <root>/project/sub, the start directory
}

@(private = "file")
write_file :: proc(t: ^testing.T, path: string, content: string) {
	directory := parent_directory(path)
	if error := os.make_directory_all(directory); error != nil && error != os.General_Error.Exist {
		testing.expectf(t, false, "cannot create %s: %v", directory, error)
	}
	testing.expect_value(t, os.write_entire_file(path, content), nil)
}

@(private = "file")
path :: proc(elements: ..string) -> string {
	joined, _ := os.join_path(elements, context.allocator)
	return joined
}

@(private = "file")
make_fixture :: proc(t: ^testing.T) -> Fixture {
	root, error := os.make_directory_temp("", "kroken-config-test-*", context.allocator)
	testing.expect_value(t, error, nil)
	config_directories := make([]string, 2)
	config_directories[0] = path(root, "etc-a")
	config_directories[1] = path(root, "etc-b")
	fixture := Fixture {
		root = root,
		environment = Environment {
			home = path(root, "home"),
			config_home = path(root, "config-home"),
			config_directories = config_directories,
			state_home = path(root, "state"),
		},
		project = path(root, "project", "sub"),
	}
	testing.expect_value(t, os.make_directory_all(fixture.project), nil)
	return fixture
}

@(private = "file")
destroy_fixture :: proc(fixture: ^Fixture) {
	_ = os.remove_all(fixture.root)
	delete(fixture.environment.home)
	delete(fixture.environment.config_home)
	for directory in fixture.environment.config_directories {
		delete(directory)
	}
	delete(fixture.environment.config_directories)
	delete(fixture.environment.state_home)
	delete(fixture.project)
	delete(fixture.root)
}

@(private = "file")
parse_or_fail :: proc(t: ^testing.T, source: string, loc := #caller_location) -> json.Object {
	root, error, ok := parse_document(source)
	if !ok {
		testing.expectf(t, false, "parse failed at %d:%d: %s", error.line, error.column, error.message, loc = loc)
		return json.Object(make(map[string]json.Value))
	}
	return root
}

@(test)
parses_sjson_documents :: proc(t: ^testing.T) {
	root := parse_or_fail(t, `
// a comment
profile = "work"     /* another */
claude = {
    model: "opus"
    tools = ["Read", "Grep",]
    max_budget_usd = 1.5
    env = { A = "1", B = "2" }
}
flag = true
count = -3
`)
	defer json.destroy_value(root)

	testing.expect_value(t, string(root["profile"].(json.String)), "work")
	claude := root["claude"].(json.Object)
	testing.expect_value(t, string(claude["model"].(json.String)), "opus")
	testing.expect_value(t, len(claude["tools"].(json.Array)), 2)
	testing.expect_value(t, f64(claude["max_budget_usd"].(json.Float)), 1.5)
	testing.expect_value(t, string(claude["env"].(json.Object)["B"].(json.String)), "2")
	testing.expect_value(t, bool(root["flag"].(json.Boolean)), true)
	testing.expect_value(t, i64(root["count"].(json.Integer)), -3)
}

@(test)
empty_documents_are_empty_objects :: proc(t: ^testing.T) {
	for source in ([]string{"", "   \n\n", "// only a comment\n", "/* block */\n"}) {
		root, error, ok := parse_document(source)
		testing.expectf(t, ok, "%q failed: %s", source, error.message)
		if ok {
			testing.expect_value(t, len(root), 0)
			json.destroy_value(root)
		}
	}
}

@(test)
reports_parse_errors_with_positions :: proc(t: ^testing.T) {
	// A "0" line means the position is not checked: the core tokenizer
	// reports a duplicate key at the position of its inserted comma.
	cases := [][3]string {
		{"a = 1\na = 2\n", "duplicate key", "0"},
		{"a = \"open\nb = 1\n", "unterminated string", "1"},
		{"x = 1\n// it's fine\ny = 'also\n", "unterminated string", "3"},
		{"a =\n", "unexpected token", "2"},
		{"a.b = 1\n", "expected '=' after the key", "1"},
		{"[1, 2]\n", "the document must consist of key = value pairs", "1"},
	}
	for test_case in cases {
		_, error, ok := parse_document(test_case[0])
		testing.expectf(t, !ok, "%q parsed but should not have", test_case[0])
		testing.expect_value(t, error.message, test_case[1])
		expected_line := int(test_case[2][0] - '0')
		testing.expectf(t, expected_line == 0 || error.line == expected_line, "%q: expected line %s, got %d", test_case[0], test_case[2], error.line)
	}
}

@(test)
merge_is_deep_and_source_wins :: proc(t: ^testing.T) {
	destination := parse_or_fail(t, `
profile = "default"
claude = { model = "opus", tools = ["Read", "Grep", "Glob"], env = { A = "1" } }
`)
	defer json.destroy_value(destination)
	source := parse_or_fail(t, `
profile = "work"
claude = { tools = ["Read"], env = { B = "2" } }
log = { enabled = false }
`)
	defer json.destroy_value(source)

	merge(&destination, source)

	testing.expect_value(t, string(destination["profile"].(json.String)), "work")
	claude := destination["claude"].(json.Object)
	testing.expect_value(t, string(claude["model"].(json.String)), "opus")
	testing.expect_value(t, len(claude["tools"].(json.Array)), 1)
	env := claude["env"].(json.Object)
	testing.expect_value(t, string(env["A"].(json.String)), "1")
	testing.expect_value(t, string(env["B"].(json.String)), "2")
	testing.expect_value(t, bool(destination["log"].(json.Object)["enabled"].(json.Boolean)), false)

	// The source is untouched and independent from the destination.
	source_claude := source["claude"].(json.Object)
	testing.expect_value(t, len(source_claude["tools"].(json.Array)), 1)
	_, source_has_model := source_claude["model"]
	testing.expect_value(t, source_has_model, false)
}

@(test)
discovers_sources_in_precedence_order :: proc(t: ^testing.T) {
	fixture := make_fixture(t)
	defer destroy_fixture(&fixture)

	system_a := path(fixture.environment.config_directories[0], "kroken", "config.sjson")
	system_b := path(fixture.environment.config_directories[1], "kroken", "config.sjson")
	user := path(fixture.environment.config_home, "kroken", "config.sjson")
	drop_in_second := path(fixture.environment.config_home, "kroken", "config.d", "20-local.sjson")
	drop_in_first := path(fixture.environment.config_home, "kroken", "config.d", "10-shared.sjson")
	not_sjson := path(fixture.environment.config_home, "kroken", "config.d", "notes.txt")
	project_outer := path(fixture.root, "project", ".kroken")
	project_inner := path(fixture.project, ".kroken")
	defer {
		delete(system_a)
		delete(system_b)
		delete(user)
		delete(drop_in_second)
		delete(drop_in_first)
		delete(not_sjson)
		delete(project_outer)
		delete(project_inner)
	}
	write_file(t, system_a, "profile = 'a'\n")
	write_file(t, system_b, "profile = 'b'\n")
	write_file(t, user, "profile = 'user'\n")
	write_file(t, drop_in_second, "profile = 'second'\n")
	write_file(t, drop_in_first, "profile = 'first'\n")
	write_file(t, not_sjson, "ignored\n")
	write_file(t, project_outer, "profile = 'outer'\n")
	write_file(t, project_inner, "profile = 'inner'\n")

	sources := discover(fixture.environment, fixture.project)
	defer destroy_sources(sources)

	expected := []string{system_b, system_a, user, drop_in_first, drop_in_second, project_outer, project_inner}
	testing.expect_value(t, len(sources), len(expected))
	for source, index in sources {
		if index < len(expected) {
			testing.expect_value(t, source.path, expected[index])
		}
	}
	if len(sources) == len(expected) {
		testing.expect_value(t, sources[0].kind, Source_Kind.System)
		testing.expect_value(t, sources[2].kind, Source_Kind.User)
		testing.expect_value(t, sources[3].kind, Source_Kind.User_Drop_In)
		testing.expect_value(t, sources[6].kind, Source_Kind.Project)
	}
}

@(test)
resolves_layers_and_profile :: proc(t: ^testing.T) {
	fixture := make_fixture(t)
	defer destroy_fixture(&fixture)

	user := path(fixture.environment.config_home, "kroken", "config.sjson")
	drop_in := path(fixture.environment.config_home, "kroken", "config.d", "50-work.sjson")
	project := path(fixture.project, ".kroken")
	defer {
		delete(user)
		delete(drop_in)
		delete(project)
	}
	write_file(t, user, `
claude = {
    model = "opus"
    tools = ["Read", "Grep", "Glob"]
}
log = { enabled = false }
`)
	write_file(t, drop_in, `
profiles = {
    work = {
        claude = {
            effort = "high"
            env = { CLAUDE_CONFIG_DIR = "~/.claude-work" }
        }
    }
}
`)
	write_file(t, project, `
profile = "work"
claude = { tools = ["Read"] }
prompt = {
    template = [
        "File: {file}"
        "{selection}"
    ]
}
`)

	resolved, message, ok := resolve(fixture.environment, fixture.project, "")
	defer delete(message)
	testing.expectf(t, ok, "resolve failed: %s", message)
	if !ok {
		return
	}
	defer destroy_resolved(&resolved)

	testing.expect_value(t, resolved.profile, "work")
	testing.expect_value(t, resolved.config.profile, "work")
	testing.expect_value(t, resolved.config.claude.model, "opus")
	testing.expect_value(t, resolved.config.claude.effort, "high")
	testing.expect_value(t, len(resolved.config.claude.tools), 1)
	testing.expect_value(t, resolved.config.claude.tools[0], "Read")
	testing.expect_value(t, len(resolved.config.claude.env), 1)
	testing.expect_value(t, resolved.config.claude.env[0].name, "CLAUDE_CONFIG_DIR")
	expected_home := path(fixture.environment.home, ".claude-work")
	defer delete(expected_home)
	testing.expect_value(t, resolved.config.claude.env[0].value, expected_home)
	testing.expect_value(t, resolved.config.backend, "claude")
	testing.expect_value(t, resolved.config.codex.command, "codex")
	testing.expect_value(t, resolved.config.codex.sandbox, "read-only")
	testing.expect_value(t, resolved.config.log.enabled, false)
	testing.expect_value(t, resolved.config.claude.command, "claude")
	testing.expect_value(t, resolved.config.prompt.system, DEFAULT_SYSTEM_PROMPT)
	testing.expect_value(t, resolved.config.prompt.template, "File: {file}\n{selection}\n")
	testing.expect_value(t, len(resolved.sources), 3)
}

@(test)
command_line_profile_beats_files :: proc(t: ^testing.T) {
	root := parse_or_fail(t, `
profile = "a"
profiles = {
    a = { claude = { model = "a-model" } }
    b = { claude = { model = "b-model" } }
}
`)
	defer json.destroy_value(root)

	name, message, ok := apply_profile(&root, "b")
	defer delete(message)
	testing.expect(t, ok)
	testing.expect_value(t, name, "b")
	testing.expect_value(t, string(root["claude"].(json.Object)["model"].(json.String)), "b-model")
	testing.expect_value(t, string(root["profile"].(json.String)), "b")
}

@(test)
missing_profile_is_an_error :: proc(t: ^testing.T) {
	root := parse_or_fail(t, "profile = \"ghost\"\n")
	defer json.destroy_value(root)
	_, message, ok := apply_profile(&root, "")
	defer delete(message)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, message, "profile \"ghost\" is not defined in any configuration file")
}

@(test)
rejects_unknown_keys_and_wrong_types :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"claude = { modle = \"opus\" }\n", "unknown key claude.modle"},
		{"claude = { tools = \"Read\" }\n", "claude.tools must be an array of strings"},
		{"claude = { tools = [1] }\n", "claude.tools must be an array of strings"},
		{"claude = { env = { A = 1 } }\n", "claude.env must be an object of strings"},
		{"log = { enabled = \"yes\" }\n", "log.enabled must be true or false"},
		{"claude = 3\n", "claude must be an object"},
		{"claude = { command = \"\" }\n", "claude.command must not be empty"},
		{"backend = \"\"\n", "backend must not be empty"},
		{"codex = { sandbox = 1 }\n", "codex.sandbox must be a string"},
		{"codex = { command = \"\" }\n", "codex.command must not be empty"},
		{"prompt = { system = [1] }\n", "prompt.system must be a string or an array of strings"},
		{"stray = true\n", "unknown key stray"},
	}
	for test_case in cases {
		root, parse_error, parse_ok := parse_document(test_case[0])
		testing.expectf(t, parse_ok, "fixture failed to parse: %s", parse_error.message)
		defer json.destroy_value(root)
		_, message, ok := from_object(root)
		defer delete(message)
		testing.expect_value(t, ok, false)
		testing.expect_value(t, message, test_case[1])
	}
}

@(test)
reads_the_codex_section_and_backend_key :: proc(t: ^testing.T) {
	root := parse_or_fail(t, `
backend = "codex"
codex = {
    model = "gpt-5.5"
    effort = "high"
    sandbox = "workspace-write"
    persist_session = true
    skip_git_repo_check = false
    env = { CODEX_HOME = "~/.codex-work" }
}
`)
	defer json.destroy_value(root)
	config, message, ok := from_object(root)
	defer delete(message)
	testing.expectf(t, ok, "from_object failed: %s", message)
	if !ok {
		return
	}
	defer destroy_config(&config)
	testing.expect_value(t, config.backend, "codex")
	testing.expect_value(t, config.codex.model, "gpt-5.5")
	testing.expect_value(t, config.codex.effort, "high")
	testing.expect_value(t, config.codex.sandbox, "workspace-write")
	testing.expect_value(t, config.codex.persist_session, true)
	testing.expect_value(t, config.codex.skip_git_repo_check, false)
	testing.expect_value(t, config.codex.env[0].name, "CODEX_HOME")

	expand_env_homes(&config, "/home/me")
	testing.expect_value(t, config.codex.env[0].value, "/home/me/.codex-work")
}

@(test)
max_budget_accepts_integers :: proc(t: ^testing.T) {
	root := parse_or_fail(t, "claude = { max_budget_usd = 2 }\n")
	defer json.destroy_value(root)
	config, message, ok := from_object(root)
	defer delete(message)
	testing.expect(t, ok)
	defer destroy_config(&config)
	testing.expect_value(t, config.claude.max_budget_usd, 2.0)
}

@(test)
dump_round_trips_defaults :: proc(t: ^testing.T) {
	config := default_config()
	defer destroy_config(&config)
	config.claude.max_budget_usd = 0.25
	config.claude.env = make([]Env_Entry, 1)
	config.claude.env[0] = Env_Entry{"CLAUDE_CONFIG_DIR", "~/.claude-work"}

	written, dump_ok := dump(config)
	testing.expect(t, dump_ok)
	defer delete(written)
	testing.expect(t, strings.contains(written, "max_budget_usd = 0.25\n"))
	testing.expect(t, strings.contains(written, "backend = \"claude\"\n"))
	testing.expect(t, strings.contains(written, "skip_git_repo_check = true\n"))
	testing.expect(t, strings.contains(written, "CLAUDE_CONFIG_DIR = \"~/.claude-work\""))
	testing.expect(t, strings.contains(written, "\"You are kroken, a code completion engine driven from a text editor.\"\n"))

	reparsed := parse_or_fail(t, written)
	defer json.destroy_value(reparsed)
	restored, message, ok := from_object(reparsed)
	defer delete(message)
	testing.expectf(t, ok, "dump did not convert: %s", message)
	if !ok {
		return
	}
	defer destroy_config(&restored)
	testing.expect_value(t, restored.claude.command, "claude")
	testing.expect_value(t, len(restored.claude.tools), 3)
	testing.expect_value(t, restored.claude.max_budget_usd, 0.25)
	testing.expect_value(t, restored.prompt.system, DEFAULT_SYSTEM_PROMPT)
	testing.expect_value(t, restored.prompt.template, DEFAULT_TEMPLATE)
	testing.expect_value(t, restored.log.enabled, true)
	testing.expect_value(t, len(restored.claude.env), 1)
	testing.expect_value(t, restored.claude.env[0].value, "~/.claude-work")
}

@(test)
walks_directories_and_finds_git_root :: proc(t: ^testing.T) {
	testing.expect_value(t, parent_directory("/a/b/c"), "/a/b")
	testing.expect_value(t, parent_directory("/a/b/"), "/a")
	testing.expect_value(t, parent_directory("/a"), "/")
	testing.expect_value(t, parent_directory("/"), "")
	testing.expect_value(t, parent_directory("relative"), "")

	ancestors := ancestor_directories("/a/b/c")
	defer delete(ancestors)
	testing.expect_value(t, len(ancestors), 4)
	testing.expect_value(t, ancestors[3], "/")

	fixture := make_fixture(t)
	defer destroy_fixture(&fixture)
	_, found_before := find_git_root(fixture.project)
	testing.expect_value(t, found_before, false)
	marker := path(fixture.root, "project", ".git")
	defer delete(marker)
	write_file(t, marker, "gitdir: elsewhere\n")
	git_root, found := find_git_root(fixture.project)
	defer delete(git_root)
	testing.expect(t, found)
	expected := path(fixture.root, "project")
	defer delete(expected)
	testing.expect_value(t, git_root, expected)
}

@(test)
expands_home :: proc(t: ^testing.T) {
	expanded := expand_home("~/.claude-work", "/home/me")
	defer delete(expanded)
	testing.expect_value(t, expanded, "/home/me/.claude-work")
	bare := expand_home("~", "/home/me")
	defer delete(bare)
	testing.expect_value(t, bare, "/home/me")
	untouched := expand_home("/abs/~/x", "/home/me")
	defer delete(untouched)
	testing.expect_value(t, untouched, "/abs/~/x")
}
