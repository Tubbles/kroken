# Editor integration

kroken is a one-shot process. The editor owns everything stateful: which job belongs to which selection, where to paste, undo. That keeps any number of runs independent, so you can trigger one, keep editing, and trigger another.

## Protocol

Invocation:

```sh
kroken complete --file <path> [--start LINE[:COLUMN]] [--end LINE[:COLUMN]] [--selection-file <path>] [--profile <name>] [--model <name>]
```

- The selection is read from `--selection-file` when given, otherwise from stdin until end of file. Prefer the file when your editor cannot close the child's stdin; micro's job API, for example, can write to stdin but never closes it.
- `--file` is the path of the buffer the selection came from. Its directory becomes the working directory of `claude`, which is what makes every `CLAUDE.md` above the file load. `--start` and `--end` are optional and only inform the prompt.
- On success the replacement text is printed to stdout with nothing added, not even a trailing newline. Paste it over the selection verbatim.
- stderr carries human-readable status: a final `kroken: done in 4.2 s, 3 turns, $0.0421` line, the log directory, and any error. Show it in the status bar or ignore it.
- Exit codes: `0` success, `1` claude ran and reported an error (stderr says why), `2` bad arguments or configuration, `3` claude could not be started or returned something unparseable. Anything but `0` means stdout holds no replacement.

A run takes anywhere from a few seconds to a few minutes depending on the model, effort, and how much of the repository it decides to read. Run it in the background.

## Pasting back after edits

The user keeps editing while the job runs, so line numbers captured at trigger time may be stale when the result arrives. Two robust strategies:

1. Remember the original selection text, and when the job exits search the buffer for that exact text and replace the first match. Simple and correct as long as the selection is not duplicated verbatim elsewhere.
2. Use editor marks that move with edits, if the editor has them.

## micro sketch

An illustration of strategy 1 with micro's Lua API, using a job callback. It is a starting point, not a supported plugin.

```lua
local micro = import("micro")
local shell = import("micro/shell")
local util = import("micro/util")
local ioutil = import("io/ioutil")

local function onExit(output, args)
    local buf, original = args[1], args[2]
    local match, found = buf:FindNext(original, buf:Start(), buf:End(), buf:Start(), true, false)
    if not found then
        micro.InfoBar():Error("kroken: original selection no longer found")
        return
    end
    buf:Replace(match[1], match[2], output)
    micro.InfoBar():Message("kroken: replaced selection")
end

function krokenComplete(bp)
    local cursor = bp.Buf:GetActiveCursor()
    if not cursor:HasSelection() then
        micro.InfoBar():Error("kroken: select something first")
        return
    end
    local original = util.String(cursor:GetSelection())
    local selectionFile = os.tmpname()
    ioutil.WriteFile(selectionFile, original, 384)
    local startLine = cursor.CurSelection[1].Y + 1
    local endLine = cursor.CurSelection[2].Y + 1
    shell.JobSpawn("kroken", {
        "complete",
        "--file", bp.Buf.AbsPath,
        "--start", tostring(startLine),
        "--end", tostring(endLine),
        "--selection-file", selectionFile,
    }, nil, nil, onExit, bp.Buf, original)
    micro.InfoBar():Message("kroken: running")
end
```

Bind it in `bindings.json`, for example `"Alt-Enter": "lua:initlua.krokenComplete"`. Every trigger spawns its own process, so overlapping runs need no extra bookkeeping. The temporary selection file is left for the operating system to clean up; delete it in `onExit` if that bothers you.
