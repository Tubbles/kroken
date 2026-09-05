# WI-0001: Core loop

Status: implemented

## Goal

`kroken complete` takes a selection plus file path, runs `claude -p` with layered TOML configuration, and prints the replacement. Covered by tests and CI.

## Scope

- TOML subset parser and writer (`src/toml`).
- Config discovery over XDG locations and `.kroken` files, deep merge, profile overlay, typed config with defaults (`src/config`).
- Prompt template rendering and language detection (`src/prompt`).
- `claude -p` command assembly, execution, result parsing, run logs (`src/claude`).
- CLI with `complete`, `config`, `version` (`src/cli`).
- Documentation: `doc/configuration.md`, `doc/editor-integration.md`, example configs in `examples/`.
- CI on GitHub Actions building and testing on every push.

## Verification

- `scripts/check.sh` green locally and in CI.
- One real end-to-end run against `claude` on a Max subscription, from a `.kroken`-carrying directory, producing a sensible function body.
