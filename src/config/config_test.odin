package config

import "core:os"
import "core:strings"
import "core:testing"
import "kroken:toml"

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
	config_home := path(root, "config-home")
	system_a := path(root, "etc-a")
	system_b := path(root, "etc-b")
	config_directories := make([]string, 2)
	config_directories[0] = system_a
	config_directories[1] = system_b
	fixture := Fixture {
		root = root,
		environment = Environment {
			home = path(root, "home"),
			config_home = config_home,
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

@(test)
discovers_sources_in_precedence_order :: proc(t: ^testing.T) {
	fixture := make_fixture(t)
	defer destroy_fixture(&fixture)

	system_a := path(fixture.environment.config_directories[0], "kroken", "config.toml")
	system_b := path(fixture.environment.config_directories[1], "kroken", "config.toml")
	user := path(fixture.environment.config_home, "kroken", "config.toml")
	drop_in_second := path(fixture.environment.config_home, "kroken", "config.d", "20-local.toml")
	drop_in_first := path(fixture.environment.config_home, "kroken", "config.d", "10-shared.toml")
	not_toml := path(fixture.environment.config_home, "kroken", "config.d", "notes.txt")
	project_outer := path(fixture.root, "project", ".kroken")
	project_inner := path(fixture.project, ".kroken")
	defer {
		delete(system_a)
		delete(system_b)
		delete(user)
		delete(drop_in_second)
		delete(drop_in_first)
		delete(not_toml)
		delete(project_outer)
		delete(project_inner)
	}
	write_file(t, system_a, "profile = 'a'\n")
	write_file(t, system_b, "profile = 'b'\n")
	write_file(t, user, "profile = 'user'\n")
	write_file(t, drop_in_second, "profile = 'second'\n")
	write_file(t, drop_in_first, "profile = 'first'\n")
	write_file(t, not_toml, "ignored\n")
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

	user := path(fixture.environment.config_home, "kroken", "config.toml")
	drop_in := path(fixture.environment.config_home, "kroken", "config.d", "50-work.toml")
	project := path(fixture.project, ".kroken")
	defer {
		delete(user)
		delete(drop_in)
		delete(project)
	}
	write_file(t, user, `
[claude]
model = "opus"
tools = ["Read", "Grep", "Glob"]
[log]
enabled = false
`)
	write_file(t, drop_in, `
[profiles.work]
[profiles.work.claude]
effort = "high"
[profiles.work.claude.env]
CLAUDE_CONFIG_DIR = "~/.claude-work"
`)
	write_file(t, project, `
profile = "work"
[claude]
tools = ["Read"]
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
	testing.expect_value(t, resolved.config.claude.env[0].value, "~/.claude-work")
	testing.expect_value(t, resolved.config.log.enabled, false)
	testing.expect_value(t, resolved.config.claude.command, "claude")
	testing.expect_value(t, resolved.config.prompt.template, DEFAULT_TEMPLATE)
	testing.expect_value(t, len(resolved.sources), 3)
}

@(test)
command_line_profile_beats_files :: proc(t: ^testing.T) {
	root, _, _ := toml.parse(`
profile = "a"
[profiles.a.claude]
model = "a-model"
[profiles.b.claude]
model = "b-model"
`)
	defer toml.destroy_table(root)

	name, message, ok := apply_profile(root, "b")
	defer delete(message)
	testing.expect(t, ok)
	testing.expect_value(t, name, "b")
	model, _ := toml.get_string(root, "claude.model")
	testing.expect_value(t, model, "b-model")
	selected, _ := toml.get_string(root, "profile")
	testing.expect_value(t, selected, "b")
}

@(test)
missing_profile_is_an_error :: proc(t: ^testing.T) {
	root, _, _ := toml.parse("profile = \"ghost\"\n")
	defer toml.destroy_table(root)
	_, message, ok := apply_profile(root, "")
	defer delete(message)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, message, "profile \"ghost\" is not defined in any configuration file")
}

@(test)
rejects_unknown_keys_and_wrong_types :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"[claude]\nmodle = \"opus\"\n", "unknown key claude.modle"},
		{"[claude]\ntools = \"Read\"\n", "claude.tools must be an array of strings"},
		{"[claude]\ntools = [1]\n", "claude.tools must be an array of strings"},
		{"[claude.env]\nA = 1\n", "claude.env must be a table of strings"},
		{"[log]\nenabled = \"yes\"\n", "log.enabled must be true or false"},
		{"claude = 3\n", "claude must be a table"},
		{"[claude]\ncommand = \"\"\n", "claude.command must not be empty"},
		{"stray = true\n", "unknown key stray"},
	}
	for test_case in cases {
		root, parse_error, parse_ok := toml.parse(test_case[0])
		testing.expectf(t, parse_ok, "fixture failed to parse: %s", parse_error.message)
		defer toml.destroy_table(root)
		_, message, ok := from_table(root)
		defer delete(message)
		testing.expect_value(t, ok, false)
		testing.expect_value(t, message, test_case[1])
	}
}

@(test)
max_budget_accepts_integers :: proc(t: ^testing.T) {
	root, _, _ := toml.parse("[claude]\nmax_budget_usd = 2\n")
	defer toml.destroy_table(root)
	config, message, ok := from_table(root)
	defer delete(message)
	testing.expect(t, ok)
	defer destroy_config(&config)
	testing.expect_value(t, config.claude.max_budget_usd, 2.0)
}

@(test)
to_table_round_trips_defaults :: proc(t: ^testing.T) {
	config := default_config()
	defer destroy_config(&config)
	tree := to_table(config)
	defer toml.destroy_table(tree)

	written := toml.write(tree)
	defer delete(written)
	reparsed, parse_error, parse_ok := toml.parse(written)
	testing.expectf(t, parse_ok, "dump did not parse: %s", parse_error.message)
	if !parse_ok {
		return
	}
	defer toml.destroy_table(reparsed)
	restored, message, ok := from_table(reparsed)
	defer delete(message)
	testing.expectf(t, ok, "dump did not convert: %s", message)
	if !ok {
		return
	}
	defer destroy_config(&restored)
	testing.expect_value(t, restored.claude.command, "claude")
	testing.expect_value(t, len(restored.claude.tools), 3)
	testing.expect_value(t, restored.prompt.system, DEFAULT_SYSTEM_PROMPT)
	testing.expect_value(t, restored.log.enabled, true)
	testing.expect(t, strings.contains(written, "tools = [\"Read\", \"Grep\", \"Glob\"]"))
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
