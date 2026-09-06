# Editor integration

kroken is a one-shot process. The editor owns everything stateful: which job belongs to which selection, where to paste, undo. That keeps any number of runs independent, so you can trigger one, keep editing, and trigger another.

## Protocol

Invocation:

```sh
kroken complete --file <path> [--start LINE[:COLUMN]] [--end LINE[:COLUMN]] [--selection-file <path>] [--profile <name>] [--model <name>]
```

- The selection is read from `--selection-file` when given, otherwise from stdin until end of file when stdin is not a terminal, otherwise lines `--start` through `--end` are taken from `--file` itself. Prefer the file when your editor cannot close the child's stdin; micro's job API, for example, can write to stdin but never closes it. The last fallback exists for shell use and for editors that have already saved the buffer.
- `--file` is the path of the buffer the selection came from. Its directory becomes the working directory of `claude`, which is what makes every `CLAUDE.md` above the file load. `--start` and `--end` are optional and only inform the prompt. Positions are 1-based and the end is inclusive.
- On success the replacement text is printed to stdout with nothing added, not even a trailing newline. Paste it over the selection verbatim.
- stderr carries human-readable status: a final `kroken: done in 4.2 s, 3 turns, $0.0421` line, the log directory, and any error. Show it in the status bar or ignore it.
- Exit codes: `0` success, `1` claude ran and reported an error (stderr says why), `2` bad arguments or configuration, `3` claude could not be started or returned something unparseable. Anything but `0` means stdout holds no replacement.

A run takes anywhere from a few seconds to a few minutes depending on the model, effort, and how much of the repository it decides to read. Run it in the background.

## Pasting back after edits

The user keeps editing while the job runs, so positions captured at trigger time may be stale when the result arrives. Two strategies:

1. Editor marks that move with edits, if the editor has them. Exact, and cheap to make safe: compare the marked text with the selection you sent before replacing it, and refuse when they differ, so edits inside the region are never clobbered.
2. Remember the original selection text, and when the job exits search the buffer for that exact text and replace the first match. Simple, but it picks the wrong spot when the selection is duplicated elsewhere, and the editor's search has to be able to match across lines.

## micro

The micro plugin lives in the [Tubbles/micro](https://github.com/Tubbles/micro) fork as the bundled `kroken` plugin (`runtime/plugins/kroken/`, branch `kroken`). Run `> help kroken` inside that build for usage. It uses strategy 1 with buffer anchors added to the fork for the purpose, and forwards any command arguments to `kroken complete`, so `> kroken --profile fast` and `> kroken --dry-run` work.

Things learned about micro's Lua job API while writing it, for anyone porting to a stock micro:

- `shell.JobSpawn` writes stdout and stderr into one buffer and hands the mix to the exit callback, so pasting the exit callback's argument would also paste the status line. Collect the streams with the separate `onStdout` and `onStderr` callbacks and ignore the exit callback's argument.
- The exit callback carries no exit status. Read `job.ProcessState:ExitCode()` on the value `JobSpawn` returned. `ProcessState` is nil when the executable could not be started at all.
- `Buffer:FindNext` matches line by line, so strategy 2 needs its own search to find a multi-line selection.
- A job's stdin is never closed, hence `--selection-file`.
