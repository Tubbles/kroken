# WI-0002: Backends on equal footing, and a manual

Status: implemented (Claude backend verified live on 2026-09-06 before the refactor; Codex backend awaits a live run, see TODO.md)

## Goal

Drive OpenAI's Codex CLI the way Claude Code is driven, with no backend assumed anywhere outside its own package, and ship the documentation as `man kroken` and `kroken help` from one source.

## Scope

- `src/backend/`: the backend interface (name, build, parse, set_model), process execution, run directory files.
- `src/backend/claude/`, `src/backend/codex/`: one package per backend, tested against recorded output.
- Configuration: `backend` key, a `codex` section beside `claude`, `--backend` and `--model` flags routed through the chosen backend.
- `kroken help [topic]` with the documents embedded at compile time.
- `doc/man/kroken.md` plus `scripts/build-man.sh`; `scripts/install.sh` installs the page; CI and releases build and attach it.

## Verification

- `scripts/check.sh` green locally and in CI.
- Dry runs for both backends through the example configuration files.
- `man -l build/kroken.1` renders every section; `man -w kroken` resolves from a prefix on PATH.
- Outstanding: one live `kroken complete --backend codex` on a machine with a Codex login.
