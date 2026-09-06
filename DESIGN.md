# Design

kroken is a one-shot command line process. The editor spawns it in the background, feeds it a selection, and pastes whatever comes back on stdout over that selection. Everything that needs state across the run (job tracking, cursor positions, undo) lives in the editor. kroken itself is stateless, which is what makes running several in parallel trivial.

## Run flow (`kroken complete`)

1. Parse flags: `--file` (required), `--start LINE[:COLUMN]`, `--end LINE[:COLUMN]`, `--selection-file`, `--profile`, `--backend`, `--model`, `--dry-run`.
2. Read the selection: `--selection-file` if given, else stdin when it is not a terminal, else lines `--start` through `--end` of the target file. With none of those, fail with a usage message rather than block on a terminal.
3. Resolve configuration (see below) starting from the directory of `--file`, then pick the backend named by the `backend` key or `--backend` from the list the CLI holds.
4. Render the prompt template with the placeholders documented in `doc/configuration.md`.
5. Create the run directory: `$XDG_STATE_HOME/kroken/log/<timestamp>-<pid>/` when logging is on, a temporary directory otherwise (and always for a dry run). It holds the prompt, any support files a backend needs (Codex reads its output schema from a file), and afterwards the command line, stderr, and raw stdout.
6. Ask the backend to build the invocation: the command line, the environment overrides, and the text the child reads on stdin. Claude Code gets the system prompt through `--append-system-prompt`; Codex has no such flag in exec mode, so its backend prepends the system prompt to the stdin text. Both get the target file's directory as working directory, so their own instruction files above the file apply (`CLAUDE.md`, `AGENTS.md`). The prompt travels on stdin from a file, which avoids argument length limits and keeps the selection out of process listings. The child's environment is the current one with the backend section's `env` entries applied on top.
7. Run it, then hand stdout and the exit code back to the backend to parse into a Result: an error flag and text, the final message, the structured replacement if the backend produced one, a session id, and a one-line summary for the status line.
8. On success print the replacement to stdout without a trailing newline added. On a backend-reported error print it to stderr and exit 1.

Exit codes: 0 success, 1 the backend reported an error, 2 usage or configuration error, 3 the backend process could not be started or produced unparseable output.

## Backends

A backend is a value of `backend.Backend`: a name, a description for help text, and three procedures. `build` turns the configuration and the two prompts into an invocation, `parse` turns the process output into a Result, `set_model` applies `--model` to the backend's own configuration section. The generic package `backend` owns process execution, the run directory files, and the environment merge, and knows nothing about any concrete backend; the CLI holds the list. Adding a backend means one package under `src/backend/`, one configuration section, and one entry in that list.

- `claude`: Claude Code, `claude -p --output-format json --json-schema ...`. The replacement arrives as a JSON string in `structured_output`. Read-only tools by default, `--add-dir <git root>` so they reach the whole repository, `--no-session-persistence` unless asked otherwise.
- `codex`: OpenAI Codex CLI, `codex exec --json --output-schema <file> -`. The JSON Lines stream is parsed for the last `agent_message` item, whose text is the schema-shaped JSON, plus `turn.completed` usage and `turn.failed` or `error` events. Read-only sandbox by default, `--ephemeral` unless asked otherwise, `--skip-git-repo-check` so files outside a repository work.

## Configuration

SJSON only, parsed by Odin's `core:encoding/json` in SJSON mode, so no parser is owned here. The schema is in `doc/configuration.md`. Layers, lowest precedence first:

1. `$XDG_CONFIG_DIRS/kroken/config.sjson` for each entry, applied from last to first so the first entry wins, per the XDG spec.
2. `$XDG_CONFIG_HOME/kroken/config.sjson`.
3. `$XDG_CONFIG_HOME/kroken/config.d/*.sjson` sorted by file name.
4. `.kroken` files from the target file's directory up to the filesystem root, applied root first so the closest file wins. With no `--file`, discovery starts at the current working directory.
5. Command line flags.

Merging is a deep merge of objects: a key in a later layer replaces the same key in an earlier one, arrays and scalars are replaced wholesale, objects are merged recursively. After all layers are merged, the `profile` key selects the member of `profiles` with that name, whose contents are deep-merged on top of the root one more time. Because `profile` itself is an ordinary key, a `.kroken` file in a work repository can select the work account while the profile's contents live in the user configuration.

Two guards sit in front of the core parser: an empty or comment-only document counts as an empty object rather than a syntax error, and a scan for unterminated strings runs first, because the core parser drops the tokenizer's error for those and would otherwise hand back an empty string.

Profiles are how "any kind of subscription" is supported: a profile is just env vars and extra flags for the `claude` process. Separate claude.ai logins live in separate `CLAUDE_CONFIG_DIR`s, API keys and cloud providers use their own env vars, and `claude` does the actual authentication.

## Packages

- `config`: file discovery, layering, deep merge of `json.Object` trees, profile overlay, conversion of the merged tree into a typed `Config` struct with defaults (one section per backend), and the dump for `kroken config` (a `json.marshal` of a mirror struct in MJSON mode, with a user marshaler so floats print short).
- `prompt`: template rendering and file extension to language mapping.
- `backend`: the backend interface, process execution with the run directory (side effects), the environment merge (pure, tested).
- `backend/claude`, `backend/codex`: command line assembly and output parsing for one backend each, pure and tested against recorded output.
- `cli`: the `main` package, which also holds the backend list.

## Non-goals for now

- A daemon or job registry. The editor owns job lifecycle.
- Writing to the target file. The editor owns the buffer.
- Streaming partial output. A completion is pasted once, whole.
- Windows and macOS builds. Nothing in the design prevents them.
