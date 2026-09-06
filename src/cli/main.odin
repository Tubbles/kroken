package main

// Command line entry point. Owns argument parsing, exit codes, and the
// wiring between the library packages. See DESIGN.md for the run flow.
// Nothing here is freed on purpose: the process is short-lived.

import "core:flags"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "kroken:claude"
import "kroken:config"
import "kroken:prompt"

VERSION :: "0.2.0"

Exit_Code :: enum int {
	Success      = 0,
	Claude_Error = 1, // claude ran and reported an error
	Usage        = 2, // bad arguments or configuration
	Runner       = 3, // claude could not be started or its output not parsed
}

USAGE :: `usage: kroken <command> [flags]

commands:
  complete   read a selection, run claude, print the replacement
  config     print the effective configuration and its sources
  version    print the version

run "kroken <command> --help" for the flags of a command
`

Complete_Options :: struct {
	file:           string `args:"name=file,required" usage:"path of the file the selection comes from"`,
	start:          string `args:"name=start" usage:"selection start as LINE[:COLUMN], 1-based; with nothing piped in, lines --start..--end are taken from --file"`,
	end:            string `args:"name=end" usage:"selection end as LINE[:COLUMN], 1-based, inclusive; defaults to --start"`,
	selection_file: string `args:"name=selection-file" usage:"read the selection from this file instead of stdin"`,
	profile:        string `args:"name=profile" usage:"configuration profile to apply, overrides the profile key"`,
	model:          string `args:"name=model" usage:"model passed to claude, overrides claude.model"`,
	dry_run:        bool `args:"name=dry-run" usage:"print the command line and prompt instead of running claude"`,
}

Config_Options :: struct {
	file:    string `args:"name=file" usage:"resolve for this file's directory instead of the working directory"`,
	profile: string `args:"name=profile" usage:"configuration profile to apply, overrides the profile key"`,
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprint(USAGE)
		os.exit(int(Exit_Code.Usage))
	}
	code := Exit_Code.Success
	switch os.args[1] {
	case "complete":
		code = run_complete(os.args[2:])
	case "config":
		code = run_config(os.args[2:])
	case "version":
		fmt.println("kroken", VERSION)
	case "-h", "--help", "help":
		fmt.print(USAGE)
	case:
		fmt.eprintf("kroken: unknown command %q\n\n", os.args[1])
		fmt.eprint(USAGE)
		code = .Usage
	}
	os.exit(int(code))
}

// `description` is printed above the flag table on --help.
parse_options :: proc(options: ^$T, arguments: []string, command_name: string, description: string) -> (ok: bool) {
	error := flags.parse(options, arguments, .Unix)
	if error == nil {
		return true
	}
	if _, is_help := error.(flags.Help_Request); is_help {
		fmt.print(description)
		flags.write_usage(os.to_stream(os.stdout), T, command_name, .Unix)
		os.exit(int(Exit_Code.Success))
	}
	flags.print_errors(T, error, command_name, .Unix)
	return false
}

run_complete :: proc(arguments: []string) -> Exit_Code {
	options: Complete_Options
	if !parse_options(&options, arguments, "kroken complete", COMPLETE_DESCRIPTION) {
		return .Usage
	}
	file, path_error := os.get_absolute_path(options.file, context.allocator)
	if path_error != nil {
		fmt.eprintf("kroken: cannot resolve %s: %v\n", options.file, path_error)
		return .Usage
	}
	directory := config.parent_directory(file)

	start_line, start_ok := parse_position(options.start)
	end_line, end_ok := parse_position(options.end)
	if !start_ok || !end_ok {
		fmt.eprintln("kroken: --start and --end must look like LINE or LINE:COLUMN")
		return .Usage
	}
	if end_line == 0 {
		end_line = start_line
	}
	if end_line < start_line || (end_line > 0 && start_line == 0) {
		fmt.eprintln("kroken: --end must not precede --start, and --end needs --start")
		return .Usage
	}
	selection_text, selection_ok := read_selection(options.selection_file, file, start_line, end_line)
	if !selection_ok {
		return .Usage
	}

	environment := config.environment_from_process()
	resolved, resolve_message, resolve_ok := config.resolve(environment, directory, options.profile)
	if !resolve_ok {
		fmt.eprintf("kroken: %s\n", resolve_message)
		return .Usage
	}
	if options.model != "" {
		resolved.config.claude.model = options.model
	}

	git_root, has_git_root := config.find_git_root(directory)
	selection := prompt.Selection {
		file          = file,
		relative_file = relative_to(file, has_git_root ? git_root : directory),
		text          = selection_text,
		start_line    = start_line,
		end_line      = end_line,
	}
	user_prompt := prompt.render(resolved.config.prompt.template, selection)

	invocation := claude.build_invocation(resolved.config.claude, resolved.config.prompt.system, directory, git_root)
	invocation.env_overrides = expand_env(resolved.config.claude.env, environment.home)

	if options.dry_run {
		print_dry_run(invocation, user_prompt)
		return .Success
	}

	log_directory := create_log_directory(resolved.config.log, environment)
	started := time.now()
	outcome, run_message, run_ok := claude.run(invocation, user_prompt, log_directory)
	if !run_ok {
		fmt.eprintf("kroken: %s\n", run_message)
		print_log_hint(log_directory)
		return .Runner
	}
	if outcome.result.is_error {
		fmt.eprintf("kroken: claude failed (%s): %s\n", outcome.result.subtype, strings.trim_space(outcome.result.text))
		print_log_hint(log_directory)
		return .Claude_Error
	}
	if outcome.result.has_replacement {
		fmt.print(outcome.result.replacement)
	} else {
		fmt.eprintln("kroken: claude returned no structured output, printing its raw result")
		fmt.print(outcome.result.text)
	}
	fmt.eprintf("kroken: done in %.1f s, %d turns, $%.4f\n", time.duration_seconds(time.since(started)), outcome.result.num_turns, outcome.result.total_cost_usd)
	print_log_hint(log_directory)
	return .Success
}

run_config :: proc(arguments: []string) -> Exit_Code {
	options: Config_Options
	if !parse_options(&options, arguments, "kroken config", config_description()) {
		return .Usage
	}
	directory: string
	if options.file != "" {
		file, path_error := os.get_absolute_path(options.file, context.allocator)
		if path_error != nil {
			fmt.eprintf("kroken: cannot resolve %s: %v\n", options.file, path_error)
			return .Usage
		}
		directory = config.parent_directory(file)
	} else {
		working_directory, directory_error := os.get_working_directory(context.allocator)
		if directory_error != nil {
			fmt.eprintf("kroken: cannot determine the working directory: %v\n", directory_error)
			return .Usage
		}
		directory = working_directory
	}

	environment := config.environment_from_process()
	resolved, message, ok := config.resolve(environment, directory, options.profile)
	if !ok {
		fmt.eprintf("kroken: %s\n", message)
		return .Usage
	}
	if len(resolved.sources) == 0 {
		fmt.println("# no configuration files found, showing the defaults")
	} else {
		fmt.println("# configuration sources, lowest precedence first:")
		for source, index in resolved.sources {
			fmt.printf("#   %d. %s (%s)\n", index + 1, source.path, source_kind_name(source.kind))
		}
	}
	fmt.printf("# profile in effect: %s\n\n", resolved.profile == "" ? "(none)" : resolved.profile)
	text, dump_ok := config.dump(resolved.config)
	if !dump_ok {
		fmt.eprintln("kroken: cannot render the configuration")
		return .Runner
	}
	fmt.println(text)
	return .Success
}

COMPLETE_DESCRIPTION :: `Reads a selection, runs claude -p with the file's directory as its working
directory (so every CLAUDE.md above the file applies), and prints the
replacement on stdout. Status goes to stderr.

`

// Built at runtime so the paths shown are the ones this machine uses.
config_description :: proc() -> string {
	environment := config.environment_from_process()
	system_directories, _ := strings.join(environment.config_directories, ", ")
	builder := strings.builder_make()
	fmt.sbprint(&builder, "Prints the configuration in effect and the files it came from.\n")
	fmt.sbprint(&builder, "Files are merged lowest precedence first, later ones overriding key by key:\n")
	fmt.sbprintf(&builder, "  1. <dir>/kroken/%s for each $XDG_CONFIG_DIRS entry, last entry first (now: %s)\n", config.CONFIG_FILE_NAME, system_directories)
	fmt.sbprintf(&builder, "  2. %s/kroken/%s\n", environment.config_home, config.CONFIG_FILE_NAME)
	fmt.sbprintf(&builder, "  3. %s/kroken/config.d/*%s, sorted by file name\n", environment.config_home, config.DROP_IN_EXTENSION)
	fmt.sbprintf(&builder, "  4. %s in the starting directory and in each parent, filesystem root first\n", config.PROJECT_FILE_NAME)
	fmt.sbprint(&builder, "  5. the selected profile (--profile, else the merged \"profile\" key) on top of everything\n")
	fmt.sbprint(&builder, "The starting directory is the directory of --file, else the working directory.\n")
	fmt.sbprintf(&builder, "Run logs go to %s/kroken/log unless log.directory says otherwise.\n\n", environment.state_home)
	return strings.to_string(builder)
}

source_kind_name :: proc(kind: config.Source_Kind) -> string {
	switch kind {
	case .System:
		return "system"
	case .User:
		return "user"
	case .User_Drop_In:
		return "user drop-in"
	case .Project:
		return "project"
	}
	return "?"
}

// LINE or LINE:COLUMN; the column is accepted for the editor's
// convenience but only the line is used in the prompt.
parse_position :: proc(text: string) -> (line: int, ok: bool) {
	if text == "" {
		return 0, true
	}
	line_text := text
	if colon := strings.index_byte(text, ':'); colon >= 0 {
		line_text = text[:colon]
	}
	line, ok = strconv.parse_int(line_text, 10)
	return line, ok && line > 0
}

// The selection comes from --selection-file, else from stdin when
// something is piped in, else from lines --start..--end of the target
// file. A terminal on stdin is never read: that only hangs.
read_selection :: proc(selection_file: string, file: string, start_line: int, end_line: int) -> (text: string, ok: bool) {
	content: []byte
	error: os.Error
	if selection_file != "" {
		content, error = os.read_entire_file_from_path(selection_file, context.allocator)
	} else if !os.is_tty(os.stdin) {
		content, error = os.read_entire_file_from_file(os.stdin, context.allocator)
	}
	if error != nil {
		fmt.eprintf("kroken: cannot read the selection: %v\n", error)
		return "", false
	}
	if len(content) > 0 {
		return string(content), true
	}
	if start_line == 0 {
		fmt.eprintln("kroken: no selection: pipe it on stdin, pass --selection-file, or give --start/--end to take those lines from --file")
		return "", false
	}
	file_content, read_error := os.read_entire_file_from_path(file, context.allocator)
	if read_error != nil {
		fmt.eprintf("kroken: cannot read %s: %v\n", file, read_error)
		return "", false
	}
	text, ok = prompt.extract_lines(string(file_content), start_line, end_line)
	if !ok {
		fmt.eprintf("kroken: %s has %d lines, cannot take lines %d-%d\n", file, prompt.count_lines(string(file_content)), start_line, end_line)
		return "", false
	}
	return text, true
}

relative_to :: proc(file: string, base: string) -> string {
	prefix := strings.concatenate({base, "/"})
	if base != "/" && strings.has_prefix(file, prefix) {
		return file[len(prefix):]
	}
	return os.base(file)
}

expand_env :: proc(entries: []config.Env_Entry, home: string) -> []config.Env_Entry {
	expanded := make([]config.Env_Entry, len(entries))
	for entry, index in entries {
		expanded[index] = config.Env_Entry{name = entry.name, value = config.expand_home(entry.value, home)}
	}
	return expanded
}

// <root>/<UTC timestamp>-<pid>, or "" when logging is off or the
// directory cannot be created (reported, not fatal).
create_log_directory :: proc(log_config: config.Log_Config, environment: config.Environment) -> string {
	if !log_config.enabled {
		return ""
	}
	root: string
	if log_config.directory != "" {
		root = config.expand_home(log_config.directory, environment.home)
	} else {
		root, _ = os.join_path({environment.state_home, "kroken", "log"}, context.allocator)
	}
	now, _ := time.time_to_datetime(time.now())
	name := fmt.aprintf("%04d%02d%02d-%02d%02d%02d-%d", now.year, now.month, now.day, now.hour, now.minute, now.second, os.get_pid())
	directory, _ := os.join_path({root, name}, context.allocator)
	if error := os.make_directory_all(directory); error != nil && error != os.General_Error.Exist {
		fmt.eprintf("kroken: cannot create log directory %s: %v\n", directory, error)
		return ""
	}
	return directory
}

print_log_hint :: proc(log_directory: string) {
	if log_directory != "" {
		fmt.eprintf("kroken: log: %s\n", log_directory)
	}
}

print_dry_run :: proc(invocation: claude.Invocation, user_prompt: string) {
	fmt.println("working directory:", invocation.working_directory)
	fmt.println("environment overrides:")
	for entry in invocation.env_overrides {
		fmt.printf("  %s=%s\n", entry.name, entry.value)
	}
	fmt.println("command:")
	for argument in invocation.command {
		fmt.printf("  %q\n", argument)
	}
	fmt.println("prompt:")
	fmt.print(user_prompt)
}
