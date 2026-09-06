package config

// Configuration discovery and layering. Precedence, lowest first:
// $XDG_CONFIG_DIRS entries (last to first), $XDG_CONFIG_HOME config,
// its config.d/ drop-ins by name, then .kroken files from the
// filesystem root down to the start directory. See DESIGN.md.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

CONFIG_FILE_NAME :: "config.sjson"
DROP_IN_EXTENSION :: ".sjson"
PROJECT_FILE_NAME :: ".kroken"

Environment :: struct {
	home:               string,
	config_home:        string, // $XDG_CONFIG_HOME or ~/.config
	config_directories: []string, // $XDG_CONFIG_DIRS in spec order, or /etc/xdg
	state_home:         string, // $XDG_STATE_HOME or ~/.local/state
}

Source_Kind :: enum {
	System,
	User,
	User_Drop_In,
	Project,
}

Source :: struct {
	path: string,
	kind: Source_Kind,
}

Resolved :: struct {
	config:  Config,
	sources: []Source, // in precedence order, lowest first
	tree:    json.Object, // the merged tree the config borrows its strings from
	profile: string,
}

environment_from_process :: proc(allocator := context.allocator) -> (environment: Environment) {
	environment.home, _ = os.user_home_dir(allocator)
	environment.config_home, _ = os.user_config_dir(allocator)
	environment.state_home, _ = os.user_state_dir(allocator)
	if directories, found := os.lookup_env("XDG_CONFIG_DIRS", allocator); found && directories != "" {
		environment.config_directories, _ = os.split_path_list(directories, allocator)
	} else {
		environment.config_directories = slice.clone([]string{"/etc/xdg"}, allocator)
	}
	return environment
}

// Runs the whole pipeline: discover, load and merge, apply the profile,
// convert to a typed config. `override_profile` comes from the command
// line and beats every file.
resolve :: proc(environment: Environment, start_directory: string, override_profile: string, allocator := context.allocator) -> (resolved: Resolved, message: string, ok: bool) {
	resolved.sources = discover(environment, start_directory, allocator)
	tree, load_error, load_ok := load_sources(resolved.sources, allocator)
	if !load_ok {
		message = format_load_error(load_error, allocator)
		destroy_sources(resolved.sources, allocator)
		return {}, message, false
	}
	resolved.tree = tree
	profile, profile_message, profile_ok := apply_profile(&resolved.tree, override_profile, allocator)
	if !profile_ok {
		destroy_resolved(&resolved, allocator)
		return {}, profile_message, false
	}
	resolved.profile = profile
	config, config_message, config_ok := from_object(resolved.tree, allocator)
	if !config_ok {
		destroy_resolved(&resolved, allocator)
		return {}, config_message, false
	}
	expand_env_homes(&config, environment.home, allocator)
	resolved.config = config
	return resolved, "", true
}

destroy_resolved :: proc(resolved: ^Resolved, allocator := context.allocator) {
	destroy_config(&resolved.config, allocator)
	destroy_sources(resolved.sources, allocator)
	json.destroy_value(resolved.tree, allocator)
	resolved^ = {}
}

destroy_sources :: proc(sources: []Source, allocator := context.allocator) {
	for source in sources {
		delete(source.path, allocator)
	}
	delete(sources, allocator)
}

// Lists the configuration files that exist, in precedence order.
discover :: proc(environment: Environment, start_directory: string, allocator := context.allocator) -> []Source {
	sources := make([dynamic]Source, allocator)
	// The first XDG_CONFIG_DIRS entry has the highest precedence, so it
	// is applied last.
	#reverse for directory in environment.config_directories {
		add_if_file(&sources, join(allocator, directory, "kroken", CONFIG_FILE_NAME), .System, allocator)
	}
	add_if_file(&sources, join(allocator, environment.config_home, "kroken", CONFIG_FILE_NAME), .User, allocator)

	drop_in_directory := join(allocator, environment.config_home, "kroken", "config.d")
	defer delete(drop_in_directory, allocator)
	names := sorted_drop_in_names(drop_in_directory, allocator)
	defer delete_strings(names, allocator)
	for name in names {
		add_if_file(&sources, join(allocator, drop_in_directory, name), .User_Drop_In, allocator)
	}

	ancestors := ancestor_directories(start_directory, allocator)
	defer delete(ancestors, allocator)
	#reverse for directory in ancestors {
		add_if_file(&sources, join(allocator, directory, PROJECT_FILE_NAME), .Project, allocator)
	}
	return sources[:]
}

@(private)
add_if_file :: proc(sources: ^[dynamic]Source, path: string, kind: Source_Kind, allocator := context.allocator) {
	if os.is_file(path) {
		append(sources, Source{path = path, kind = kind})
	} else {
		delete(path, allocator)
	}
}

@(private)
join :: proc(allocator: runtime.Allocator, elements: ..string) -> string {
	joined, _ := os.join_path(elements, allocator)
	return joined
}

@(private)
delete_strings :: proc(items: []string, allocator := context.allocator) {
	for item in items {
		delete(item, allocator)
	}
	delete(items, allocator)
}

@(private)
sorted_drop_in_names :: proc(directory: string, allocator := context.allocator) -> []string {
	infos, error := os.read_all_directory_by_path(directory, allocator)
	if error != nil {
		return nil
	}
	defer os.file_info_slice_delete(infos, allocator)
	names := make([dynamic]string, allocator)
	for info in infos {
		if info.type != .Directory && strings.has_suffix(info.name, DROP_IN_EXTENSION) {
			append(&names, strings.clone(info.name, allocator))
		}
	}
	slice.sort(names[:])
	return names[:]
}

// The directory itself first, then each parent up to and including the
// filesystem root. Slices of `start`, nothing to free but the slice.
ancestor_directories :: proc(start: string, allocator := context.allocator) -> []string {
	directories := make([dynamic]string, allocator)
	current := start
	for current != "" {
		append(&directories, current)
		current = parent_directory(current)
	}
	return directories[:]
}

// "" once the root has been passed, so callers can loop until empty.
parent_directory :: proc(path: string) -> string {
	if path == "/" || path == "" {
		return ""
	}
	trimmed := strings.trim_right(path, "/")
	last_separator := strings.last_index_byte(trimmed, '/')
	if last_separator < 0 {
		return ""
	}
	if last_separator == 0 {
		return "/"
	}
	return trimmed[:last_separator]
}

// Walks up from `start` looking for a .git entry (a directory, or the
// file a worktree leaves behind).
find_git_root :: proc(start: string, allocator := context.allocator) -> (root: string, found: bool) {
	current := start
	for current != "" {
		marker := join(allocator, current, ".git")
		defer delete(marker, allocator)
		if os.exists(marker) {
			return strings.clone(current, allocator), true
		}
		current = parent_directory(current)
	}
	return "", false
}

// Expands a leading "~" or "~/" to the home directory. Always allocates.
expand_home :: proc(path: string, home: string, allocator := context.allocator) -> string {
	if path == "~" {
		return strings.clone(home, allocator)
	}
	if strings.has_prefix(path, "~/") {
		return strings.concatenate({home, path[1:]}, allocator)
	}
	return strings.clone(path, allocator)
}

Load_Error :: struct {
	path:        string,
	parse_error: Parse_Error,
}

format_load_error :: proc(error: Load_Error, allocator := context.allocator) -> string {
	if error.parse_error.line > 0 {
		return fmt.aprintf("%s:%d:%d: %s", error.path, error.parse_error.line, error.parse_error.column, error.parse_error.message, allocator = allocator)
	}
	return fmt.aprintf("%s: %s", error.path, error.parse_error.message, allocator = allocator)
}

// Parses every source and merges them in order into one tree.
load_sources :: proc(sources: []Source, allocator := context.allocator) -> (root: json.Object, error: Load_Error, ok: bool) {
	root = json.Object(make(map[string]json.Value, allocator))
	for source in sources {
		content, read_error := os.read_entire_file_from_path(source.path, allocator)
		if read_error != nil {
			json.destroy_value(root, allocator)
			return nil, Load_Error{path = source.path, parse_error = {message = "cannot read file"}}, false
		}
		defer delete(content, allocator)
		if !merge_document(&root, string(content), source.path, &error, allocator) {
			json.destroy_value(root, allocator)
			return nil, error, false
		}
	}
	return root, {}, true
}

// Parses one document and merges it into `root`, for tests and callers
// that hold the content already.
merge_document :: proc(root: ^json.Object, content: string, path: string, error: ^Load_Error, allocator := context.allocator) -> bool {
	tree, parse_error, parse_ok := parse_document(content, allocator)
	if !parse_ok {
		error^ = Load_Error{path = path, parse_error = parse_error}
		return false
	}
	defer json.destroy_value(tree, allocator)
	merge(root, tree, allocator)
	return true
}

// Applies `profiles.<name>` on top of the root, where name is the
// override when given, else the merged `profile` key. Returns the name
// in effect, borrowed from the tree.
apply_profile :: proc(root: ^json.Object, override: string, allocator := context.allocator) -> (name: string, message: string, ok: bool) {
	if override != "" {
		set_value(root, "profile", json.String(strings.clone(override, allocator)), allocator)
	}
	if value, present := root["profile"]; present {
		text, is_string := value.(json.String)
		if !is_string {
			return "", strings.clone("profile must be a string", allocator), false
		}
		name = string(text)
	}
	if name == "" {
		return "", "", true
	}
	profile: json.Object
	if profiles, has_profiles := root["profiles"].(json.Object); has_profiles {
		profile, _ = profiles[name].(json.Object)
	}
	if profile == nil {
		return "", fmt.aprintf("profile %q is not defined in any configuration file", name, allocator = allocator), false
	}
	overlay := clone_value(profile, allocator).(json.Object)
	defer json.destroy_value(overlay, allocator)
	// The overlay must not change which profile is selected, and the
	// name returned above points into the root's current string.
	remove_key(&overlay, "profile", allocator)
	remove_key(&overlay, "profiles", allocator)
	merge(root, overlay, allocator)
	return name, "", true
}
