# WI-0002: Backends on equal footing, and a manual

Status: verified (Claude backend live on 2026-09-06 before the refactor; Codex backend live on 2026-09-06 with a Free ChatGPT plan, log 20260906-163900-57828)

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
- Live Codex run: a fixture whose AGENTS.md demanded Allman braces, 4-space indent, and a `remainder` temporary got exactly that back in 11 s; the event stream was thread.started, turn.started, item.completed (agent_message), turn.completed, as the parser expects.
