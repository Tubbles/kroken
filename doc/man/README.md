# Man page source

`kroken.md` is the man-specific part of `kroken(1)`: NAME, SYNOPSIS, COMMANDS, EXIT STATUS, ENVIRONMENT, FILES. `scripts/build-man.sh` replaces `@VERSION@`, `@DATE@`, `@COMPLETE_HELP@`, and `@CONFIG_HELP@` (the latter two with the binary's own `--help` output), appends `doc/configuration.md` and `doc/editor-integration.md` with their headings shifted one level, and converts the result with go-md2man into `build/kroken.1`. Nothing in this directory duplicates those documents; edit them, not this file, for anything but the man-specific sections.
