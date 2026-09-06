# Design

kroken is a one-shot command line process. The editor spawns it in the background, feeds it a selection, and pastes whatever comes back on stdout over that selection. Everything that needs state across the run (job tracking, cursor positions, undo) lives in the editor. kroken itself is stateless, which is what makes running several in parallel trivial.

## Run flow (`kroken complete`)

1. Parse flags: `--file` (required), `--start LINE[:COLUMN]`, `--end LINE[:COLUMN]`, `--selection-file`, `--profile`, `--model`, `--dry-run`.
2. Read the selection: `--selection-file` if given, else stdin when it is not a terminal, else lines `--start` through `--end` of the target file. With none of those, fail with a usage message rather than block on a terminal.
3. Resolve configuration (see below) starting from the directory of `--file`.
4. Render the prompt template with the placeholders documented in `doc/configuration.md`.
5. Assemble the `claude -p` command line: `--output-format json`, `--json-schema` requesting `{"replacement": string}`, `--append-system-prompt` with the configured system prompt, `--tools`, `--model`, `--effort`, `--add-dir <git root>`, `--no-session-persistence`, `--max-budget-usd`, then `extra_args` verbatim.
6. Run it with the target file's directory as working directory, so Claude Code loads `~/.claude/CLAUDE.md` and every `CLAUDE.md` or `CLAUDE.local.md` above the file. The prompt is written to a file and given to the child as stdin, which avoids argument length limits and keeps the selection out of process listings. The child's environment is the current one with the profile's `[claude.env]` entries applied on top.
7. Parse the JSON result. On success print `structured_output.replacement` to stdout without a trailing newline added. On `is_error` print the `result` text to stderr and exit 1.
8. If logging is enabled, the prompt, command line, stderr and result JSON are kept under `$XDG_STATE_HOME/kroken/log/<timestamp>-<pid>/`.

Exit codes: 0 success, 1 claude reported an error, 2 usage or configuration error, 3 the `claude` process could not be started or produced unparseable output.

## Configuration

TOML only. The schema is in `doc/configuration.md`. Layers, lowest precedence first:

1. `$XDG_CONFIG_DIRS/kroken/config.toml` for each entry, applied from last to first so the first entry wins, per the XDG spec.
2. `$XDG_CONFIG_HOME/kroken/config.toml`.
3. `$XDG_CONFIG_HOME/kroken/config.d/*.toml` sorted by file name.
4. `.kroken` files from the target file's directory up to the filesystem root, applied root first so the closest file wins. With no `--file`, discovery starts at the current working directory.
5. Command line flags.

Merging is a deep merge of tables: a key in a later layer replaces the same key in an earlier one, arrays and scalars are replaced wholesale, tables are merged recursively. After all layers are merged, the `profile` key selects `[profile.<name>]`, whose contents are deep-merged on top of the root one more time. Because `profile` itself is an ordinary key, a `.kroken` file in a work repository can select the work account while the profile's contents live in the user configuration.

Profiles are how "any kind of subscription" is supported: a profile is just env vars and extra flags for the `claude` process. Separate claude.ai logins live in separate `CLAUDE_CONFIG_DIR`s, API keys and cloud providers use their own env vars, and `claude` does the actual authentication.

## Packages

- `toml`: a hand-written subset parser (tables, dotted keys, basic and literal strings including multi-line, integers, floats, booleans, arrays, inline tables) producing an ordered tree, and a writer for `kroken config`. Arrays of tables and date/time values are rejected with a clear error. No dependencies.
- `config`: file discovery, layering, merging, profile overlay, and conversion of the merged tree into a typed `Config` struct with defaults.
- `prompt`: template rendering and file extension to language mapping.
- `claude`: command line assembly (pure, tested), process execution (side effects), result parsing (pure, tested).
- `cli`: the `main` package.

## Non-goals for now

- A daemon or job registry. The editor owns job lifecycle.
- Writing to the target file. The editor owns the buffer.
- Streaming partial output. A completion is pasted once, whole.
- Windows and macOS builds. Nothing in the design prevents them.
