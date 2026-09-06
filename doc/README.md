# Documentation index

Living documentation for kroken. Markdown convention: one paragraph per line, let the renderer wrap. `configuration.md` and `editor-integration.md` are embedded in the binary (`kroken help config`, `kroken help editor`) and assembled into the man page, so they are written to read well as plain text too.

- [configuration.md](configuration.md) is the configuration reference: file locations, precedence, every key, prompt placeholders, profiles.
- [editor-integration.md](editor-integration.md) describes the protocol between an editor and kroken, and where the micro plugin lives.
- [man/](man/) holds the man-only sections of `kroken(1)`; `scripts/build-man.sh` appends the documents above to them.
- [log/](log/) holds write-once decision logs, one file per day, tagged for grepping.
- [work/](work/) holds work items with status (todo, implemented, verified).
