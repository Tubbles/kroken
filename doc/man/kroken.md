# kroken 1 "@DATE@" "kroken @VERSION@" "User Commands"

## NAME

kroken - LLM coding harness driven from a text editor

## SYNOPSIS

**kroken complete** **--file** *path* [**--start** *LINE[:COLUMN]*] [**--end** *LINE[:COLUMN]*] [**--selection-file** *path*] [**--profile** *name*] [**--backend** *name*] [**--model** *name*] [**--dry-run**]

**kroken config** [**--file** *path*] [**--profile** *name*]

**kroken help** [*topic*]

**kroken version**

## DESCRIPTION

kroken (Swedish for "the hook") replaces a selected region of a source file with what a coding agent writes for it. The editor hands kroken the selection and the file path, kroken runs an agent CLI in headless mode with the file's directory as working directory, and the replacement comes back on stdout for the editor to paste over the selection. Every run is an independent process, so any number can run in parallel while the user keeps editing.

Two backends exist and are configured side by side: **claude** runs Claude Code (`claude -p`) and **codex** runs OpenAI Codex CLI (`codex exec`). kroken never authenticates; each backend uses whatever login its own CLI has, and its own instruction files above the target file apply (CLAUDE.md, AGENTS.md).

This page is assembled from the same Markdown files that **kroken help** prints, so the two never disagree.

## COMMANDS

### complete

Reads a selection and prints the replacement. The selection comes from **--selection-file** when given, else from stdin when it is not a terminal, else from lines **--start** through **--end** of the file. With no selection at all it fails instead of blocking.

@COMPLETE_HELP@

### config

Prints the configuration in effect and the files it came from, defaults included. **--file** starts project-file discovery from that file's directory instead of the working directory.

@CONFIG_HELP@

### help

Prints a documentation topic: **overview**, **config**, or **editor**. Without a topic, lists them.

### version

Prints the version.

## EXIT STATUS

**0** success, the replacement is on stdout. **1** the backend ran and reported an error. **2** bad arguments or configuration. **3** the backend could not be started or its output could not be parsed. Anything but 0 means stdout holds no replacement.

## ENVIRONMENT

**XDG_CONFIG_HOME**, **XDG_CONFIG_DIRS**, **XDG_STATE_HOME** decide where configuration and run logs live, per the XDG base directory specification. Backend logins are the backends' own affair: **CLAUDE_CONFIG_DIR** and **ANTHROPIC_API_KEY** for Claude Code, **CODEX_HOME** and **OPENAI_API_KEY** for Codex, set per profile through the configuration.

## FILES

*~/.config/kroken/config.sjson*, *~/.config/kroken/config.d/\*.sjson*, and a *.kroken* file in the target file's directory or any parent. Run logs under *~/.local/state/kroken/log/*. See CONFIGURATION below.
