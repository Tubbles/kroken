# kroken

kroken (Swedish for "the hook") is an LLM harness for coding, driven from a text editor. Select a region of a source file, hand it to kroken, keep editing, and the region is replaced with what the model wrote. It is code completion on steroids: select a comment that says what a function should do together with an empty skeleton, and the body gets filled in.

kroken is a thin, one-shot command line tool written in [Odin](https://odin-lang.org/). It runs `claude -p` (Claude Code headless mode) under the hood, so it works with any Anthropic subscription or provider that `claude` itself supports.

Status: early. Linux amd64 only for now.

## How it works

1. The editor sends the selected text (on stdin or via `--selection-file`) together with the path of the file it came from.
2. kroken assembles a prompt from a configurable template, resolves layered configuration, and runs `claude -p` with the file's directory as working directory. Claude Code loads every `CLAUDE.md` above that directory, plus `~/.claude/CLAUDE.md`, exactly as an interactive session would.
3. The replacement text comes back on stdout. The editor pastes it over the original selection.

Each invocation is an independent process, so any number of them can run in parallel while you keep editing.

## Building

```sh
scripts/setup-toolchain.sh   # downloads the pinned Odin release into toolchain/ (git ignored)
scripts/check.sh             # runs the tests and builds build/kroken
```

Put `build/kroken` on your `PATH`, for example with a symlink into `~/.local/bin`.

## Usage

```sh
kroken complete --file path/to/source.c --start 12:1 --end 20:1 < selection.txt
kroken complete --file path/to/source.c --selection-file /tmp/selection.txt
kroken config --file path/to/source.c    # print the effective configuration and where it came from
kroken version
```

See [doc/README.md](doc/README.md) for the configuration reference and the editor integration protocol.

## Configuration

TOML files, layered from general to specific. Later layers override earlier ones key by key:

1. `$XDG_CONFIG_DIRS/kroken/config.toml` (default `/etc/xdg`)
2. `$XDG_CONFIG_HOME/kroken/config.toml` (default `~/.config`)
3. `$XDG_CONFIG_HOME/kroken/config.d/*.toml`, sorted by file name
4. `.kroken` files found in the target file's directory and all of its parents, applied from the filesystem root downwards, so the closest file wins
5. Command line flags

Split settings across `config.d/` files to keep some of them in version control and machine-local ones (API keys, alternate `CLAUDE_CONFIG_DIR`) out of it.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
