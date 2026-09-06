# kroken

LLM coding harness driven from a text editor, written in Odin. Wraps `claude -p`. Read `DESIGN.md` before changing behaviour and `doc/README.md` for the documentation index.

## Build and test

- `scripts/setup-toolchain.sh` installs the pinned Odin release into `toolchain/` (git ignored). Run once per clone.
- `scripts/check.sh` is the quality gate: `odin test` for every package under `src/` with `-vet -strict-style -warnings-as-errors`, then `scripts/build.sh`.
- `scripts/build.sh` builds `build/kroken`. `scripts/install.sh [prefix]` builds and copies it to `<prefix>/bin` (default `~/.local`).
- CI (`.github/workflows/ci.yml`) runs the same two scripts. A `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which refuses the tag unless `VERSION` in `src/cli/main.odin` matches, then attaches the binary to a GitHub release.
- Never bump the Odin version casually. Odin is pre-1.0 and monthly releases break things. Bumping means updating tag and sha256 in `scripts/setup-toolchain.sh` and running the full check.

## Layout

- `src/cli/` is the `main` package and owns argument parsing, exit codes, and wiring only.
- `src/config/` discovers, layers, and merges SJSON configuration files (`sjson.odin` wraps `core:encoding/json` in SJSON mode), applies profiles, and produces the typed config and its dump.
- `src/prompt/` renders the prompt template and detects the language from the file name.
- `src/backend/` is the backend interface plus process execution; `src/backend/claude/` and `src/backend/codex/` each assemble one command line and parse one output format. Nothing outside a backend's own package may assume that backend; the CLI only holds the list.
- Packages are imported through the `kroken` collection: `import "kroken:config"`.
- Configuration files are SJSON (Bitsquid simplified JSON); never reintroduce a hand-written parser, the core library's SJSON mode is the parser.
- `doc/` holds the living documentation, `doc/log/` write-once decision logs by date, `doc/work/` work items.
- `tmp/`, `work/`, `build/`, `toolchain/` are git ignored.

## Conventions

- Odin style: snake_case procedures and variables, Ada_Case types, SCREAMING_CASE constants. Never abbreviate identifiers (`index`, not `i`; `error`, not `err`).
- Small pure procedures, structs as data carriers. Side effects (filesystem, processes) live at the edges: `src/cli/` and the run procedure in `src/claude/`.
- Every package has tests next to the code (`*_test.odin`). Tests must not require network access or a working `claude` binary.
- Keep `README.md`, `DESIGN.md`, `doc/configuration.md`, and `doc/editor-integration.md` in sync with behaviour changes in the same commit.
- Markdown: one paragraph per line, never reflow.
