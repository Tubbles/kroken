# TODO

User inbox for new work items. Fully fleshed out items get moved into `doc/work/`.

## Possible action items

- Run the Codex backend live once on a machine with a Codex login: `kroken complete --backend codex --file <f> --start N`. It was built from OpenAI's documented event stream and CLI reference only; the two things to confirm are that `codex exec -` reads the prompt from stdin while `--output-schema` is set, and that the final `agent_message` text is the schema-shaped JSON (see `src/backend/codex/codex.odin`, `parse`).
