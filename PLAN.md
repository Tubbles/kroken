# Plan

## End goal

A dependable editor-driven completion harness: select, trigger, keep working, get the result pasted in. Works with whatever `claude` is logged in as, configurable per machine, per user, and per project without leaking machine-local secrets into git.

## Milestones

1. **Core loop** (in progress, see `doc/work/WI-0001-core-loop.md`): TOML config, layered discovery, prompt rendering, `claude -p` execution with structured output, run logs, CI.
2. **Editor integration** (done for micro, 2026-09-06): the bundled `kroken` plugin in the Tubbles/micro fork spawns kroken as a background job, tracks the selection with a buffer anchor, and pastes the result. It lives outside this repository, which documents the protocol in `doc/editor-integration.md`.
3. **Quality of life**: named prompt presets selectable from the editor (explain, refactor, write tests), session resume for follow-up instructions, cost reporting.

## Not planned

Anything that makes kroken stateful. See the non-goals in `DESIGN.md`.
