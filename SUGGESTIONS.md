# Suggestions

Ideas noticed during implementation that nobody asked for yet. Each cites where it would land and why it was left out.

- **Process timeout.** `claude.run` in `src/claude/run.odin` waits forever; a hung `claude` can only be killed by the editor. A `claude.timeout_seconds` key would need `os.process_start` plus `os.process_wait` with a timeout instead of `os.process_exec`, and a thread or non-blocking pipe reads. Left out because the editor already owns job lifecycle.
- **Log pruning.** Nothing deletes `$XDG_STATE_HOME/kroken/log/*`. A `log.keep = N` key applied in `create_log_directory` in `src/cli/main.odin` would cap it. Left out as unrequested.
- **Local time in log directory names.** `create_log_directory` uses `time.now()`, which is UTC, so the names lag local time by the timezone offset. Odin's `core:time` has no local-time conversion without `core:time/timezone`; check that package when it matters.
- **Token usage in the status line.** `result.json` carries `usage` with cache read and write counts; `parse_result` in `src/claude/claude.odin` ignores it. Surfacing cache hit rate on stderr would show whether the system prompt caches across runs.
- **`--permission-prompts none` by default.** It tells Claude not to retry denied actions and requires Claude Code 2.1.259 or newer. Not a default today because kroken has no minimum `claude` version; add it via `claude.extra_args` when wanted.
- **`.kroken` as a directory.** Large projects might want `.kroken/*.toml` like `config.d/`. `discover` in `src/config/discover.odin` would need one more branch. Left out for simplicity.
- **Trailing newline policy.** The replacement is pasted verbatim, and the live test showed the model mirrors the selection's trailing newline. If an editor strips or adds one, a `--match-trailing-newline` flag in `run_complete` could normalise it. Not needed so far.
- **Windows and macOS.** `parent_directory` and the XDG lookups in `src/config/discover.odin` assume `/` separators and POSIX paths. Nothing else is platform specific.
