# Configuration reference

kroken reads SJSON files: Bitsquid's simplified JSON ([specification](https://bitsquid.blogspot.com/2009/10/simplified-json-notation.html)), parsed with Odin's `core:encoding/json` in its SJSON mode. Run `kroken config` (optionally with `--file path` and `--profile name`) to print the files that were found and the effective values, defaults included. `kroken config --help` lists the search locations with the paths this machine uses.

## Syntax in one minute

```
// line comment, /* block comment */
profile = "work"             // = or : between key and value, no commas needed between lines
claude = {
    model = "opus"
    tools = ["Read", "Grep"]  // commas inside a line, a trailing one is fine
    max_budget_usd = 0.5
    env = {
        CLAUDE_CONFIG_DIR = "~/.claude-work"
    }
}
prompt = {
    template = [              // multi-line text: an array of lines, joined with newlines, ending in one
        "File: {location}"
        ""
        "{selection}"
    ]
}
```

The root object has no surrounding braces. Keys are bare identifiers or quoted strings; nested objects are written with braces, there are no dotted keys. Strings use double or single quotes and JSON escapes; a raw newline inside a string is an error, which is why multi-line text takes the array form. Numbers, `true`, and `false` are as in JSON.

## Locations and precedence

Lowest precedence first. Every later layer overrides the earlier ones key by key.

| # | Location | Purpose |
|---|----------|---------|
| 1 | `<dir>/kroken/config.sjson` for each `<dir>` in `$XDG_CONFIG_DIRS` (default `/etc/xdg`) | Machine-wide defaults. Earlier entries in the variable win over later ones, per the XDG specification. |
| 2 | `$XDG_CONFIG_HOME/kroken/config.sjson` (default `~/.config/kroken/config.sjson`) | Your defaults. |
| 3 | `$XDG_CONFIG_HOME/kroken/config.d/*.sjson`, sorted by file name | Your defaults, split across files. Keep `10-shared.sjson` in your dotfiles repository and `90-local.sjson` out of it. |
| 4 | `.kroken` in the target file's directory and every parent, applied from the filesystem root downwards | Project settings, in the same syntax. The file closest to the target wins. With no `--file`, discovery starts at the working directory. |
| 5 | Command line flags (`--profile`, `--model`) | This run only. |

An empty file, or one holding only comments, is valid and changes nothing.

## Merge rules

Objects merge recursively. Any other value, arrays included, replaces the value from the layer below wholesale. A `tools = ["Read"]` in a `.kroken` file therefore replaces the whole list, it does not append.

## Profiles

A profile is a named member of the `profiles` object holding any of the keys below. After all layers are merged, the `profile` key names the profile to apply, and that member is merged on top of everything one more time. `--profile` on the command line beats the key. Naming a profile that no file defines is an error.

Because `profile` is an ordinary key, a `.kroken` in a work repository can select `profile = "work"` while the profile's contents (an alternate `CLAUDE_CONFIG_DIR`, an API key) stay in a machine-local file under `config.d/`.

Profiles are how different subscriptions and providers are used. kroken never authenticates; it only sets environment variables and flags for the `claude` process:

- A second claude.ai login: run `CLAUDE_CONFIG_DIR=~/.claude-work claude` once to log in, then put `CLAUDE_CONFIG_DIR = "~/.claude-work"` in the profile's `claude.env`.
- An API key: `ANTHROPIC_API_KEY` in `claude.env`.
- Bedrock, Vertex, Foundry: the environment variables Claude Code documents for them, in `claude.env`.

## Keys

Values shown are the defaults.

```
profile = ""                        // name of the profiles member to apply

claude = {
    command = "claude"              // executable, resolved through PATH
    model = ""                      // --model; empty leaves the choice to claude
    effort = ""                     // --effort (low, medium, high, xhigh, max); empty leaves it to claude
    tools = ["Read", "Grep", "Glob"] // --tools; the built-in tools the model may use. [] disables all tools
    extra_args = []                 // appended to the command line verbatim, after every other flag
    persist_session = false         // false passes --no-session-persistence so runs do not pile up under ~/.claude/projects
    max_budget_usd = 0              // --max-budget-usd when greater than zero
    add_git_root = true             // pass --add-dir <git root> so read-only tools can reach the whole repository
    env = {}                        // environment variables set for the claude process; "~/" is expanded
}

prompt = {
    system = "..."                  // passed with --append-system-prompt; see `kroken config` for the default text
    template = "..."                // the user prompt, rendered with the placeholders below
}

log = {
    enabled = true                  // keep per-run logs
    directory = ""                  // empty means $XDG_STATE_HOME/kroken/log (default ~/.local/state/kroken/log); "~/" is expanded
}

profiles = {                        // members hold any of the keys above, applied when profile names them
}
```

`prompt.system` and `prompt.template` accept either a string or an array of strings. The array form is joined with newlines and gets a trailing newline, which is how `kroken config` prints them back.

Unknown keys and values of the wrong type are errors, so typos surface instead of silently keeping a default.

## Prompt placeholders

Only `prompt.template` is rendered; `prompt.system` is passed as given. Placeholders:

| Placeholder | Value |
|-------------|-------|
| `{file}` | Absolute path of the target file. |
| `{relative_file}` | Path relative to the git root, or the base name when there is no repository. |
| `{language}` | Language name derived from the file name, or the bare extension for unknown ones. |
| `{selection}` | The selected text, verbatim. |
| `{start_line}`, `{end_line}` | 1-based line numbers from `--start` and `--end`, `0` when not given. |
| `{location}` | `path, lines 10-20`, `path, line 10`, or just `path`, depending on what is known. |

An unknown placeholder is left in the text as written, so a typo is visible in the run log.

## Run logs

Each run gets `<log directory>/<UTC timestamp>-<pid>/` containing `command.txt` (working directory, names of overridden environment variables, the full argument list), `prompt.txt` (what went to `claude` on stdin), `stderr.txt`, and `result.json` (the raw `claude` output including cost and session id). Nothing prunes this directory; delete it when it grows old.
