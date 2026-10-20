# psst.nvim

> Psst. Quick question about this code.

`psst.nvim` gives you a short path from *“what is going on here?”* to a useful
answer without turning Neovim into a chat application.

Open a small prompt from the code you are already reading. Your selection,
diagnostic, surrounding semantic block, files, and symbols are available as context.
Press Enter and the answer streams beside the editor. Read it, ask a follow-up, close
it, and keep working. When the answer should become code instead of advice, send it
back into the original selection or cursor position.

No browser tab. No copy-paste ceremony. No permanent chatbot panel competing with
your buffers. Just a quiet aside when you need one.

## The loop

[![Psst asking a contextual question in Neovim](https://github.com/arubertoson/psst.nvim/releases/download/demo/demo.gif)](https://github.com/arubertoson/psst.nvim/releases/tag/demo)

1. Stop on confusing code, a diagnostic, or an unfinished edit.
2. Open `psst` without leaving the buffer.
3. Ask the small question that unblocks the work.
4. Inspect the answer beside the code—or generate directly into the editor.
5. Continue where you were.

The editor interaction is the product. Pi is merely the first harness behind it.

## What it does

- Captures visual selections and the exact invocation buffer, cursor, working
  directory, and filetype.
- Finds a bounded semantic block with Treesitter, falling back to nearby lines when
  syntax context is unavailable.
- Adds diagnostics, files, line ranges, and symbols through inline `@` references.
- Shows a responsive prompt with a context overview before anything is sent.
- Streams thinking progress and Markdown answers into a side float without stealing
  the source buffer.
- Keeps in-memory inquiry sessions so a quick follow-up is still quick.
- Generates or replaces code at the original editor location and selects the result.
- Provides optional Blink completion sources for file and symbol references.

## What it deliberately is not

`psst.nvim` is not an autonomous coding environment, an agent dashboard, or a
provider-neutral framework that flattens every harness into the same feature set. It
does not scan your repository in the background or keep a permanent conversation
pane open. Its optional global navigation mappings never replace existing keys.

It is optimized for brief, contextual inquiries made in the middle of editing.

## Status

This is personal software published in the open because inspectable tools are better
tools. It is built around how I use Neovim and may change when that workflow changes.
It has no compatibility promise, public roadmap, support commitment, or contribution
process.

The repository is source-available, not open source. No license to copy, modify, or
redistribute the code is granted. See [LICENSE](LICENSE).

## Requirements

- Neovim 0.11 or newer;
- [Pi](https://github.com/badlogic/pi-mono) available as `pi`, or a compatible Pi
  executable configured explicitly;
- Treesitter parsers for semantic context collection;
- `nvim-treesitter-textobjects` queries for the best block selection behavior.

Blink is optional and used only for prompt-reference completion.

Run `:checkhealth psst` to verify the configured harness executable.

## Installation

Using Neovim's built-in package manager:

```lua
vim.pack.add({
    { src = "https://github.com/nvim-treesitter/nvim-treesitter" },
    { src = "https://github.com/nvim-treesitter/nvim-treesitter-textobjects" },
    { src = "https://github.com/arubertoson/psst.nvim" },
})

require("psst").setup()
```

`psst.nvim` does not map a prompt-opening key. A minimal entry point is:

```lua
vim.keymap.set({ "n", "x" }, "<leader>p", function()
    local mode = vim.fn.mode()
    local visual = (mode == "v" or mode == "V" or mode == "\22") and mode or nil
    if visual then
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
            "x",
            false
        )
    end
    require("psst").prompt({ visual_mode = visual })
end, { desc = "Psst: quick question" })
```

## Prompt controls

| Mapping | Action |
| --- | --- |
| `<CR>` | Ask, continuing the selected session if its working directory matches |
| `<C-CR>` | Ask in a fresh session |
| `<C-g>` | Generate into the original selection or cursor position |
| `<C-x>` | Inspect the context that will be sent |
| `<M-CR>` | Insert a newline |
| `<Esc>` | Close the prompt |

Generate is a one-shot request, independent of inquiry sessions. Output is buffered
until completion, then inserted at the captured cursor or used to replace the
original visual selection. The result becomes selected for another edit or
generation request; normal undo reverts the change.

## Inline context

Add references directly to the prompt:

| Form | Context |
| --- | --- |
| `@lua/psst/init.lua` | Whole file |
| `@lua/psst/init.lua:120-180` | Inclusive, 1-based line range |
| `@lua/psst/init.lua#M.send` | Named symbol in that file |
| `@#M.send` | Named symbol in the invocation buffer |

Relative paths use the working directory captured when the prompt opens. Symbols
must match one Treesitter-indexed name exactly; missing or ambiguous names cannot
be submitted. Directories and paths containing whitespace are not supported.
References can be wrapped in Markdown backticks, but backticks do not allow spaces
in paths. Optional Blink sources complete project files after `@` and symbols after
`#`.

References read loaded buffers, including unsaved changes; other files are loaded
into hidden buffers. Editing or deleting a reference updates the derived context.
Submission resolves every reference again and refuses incomplete or unresolved
references without closing the prompt.

Inline context is combined with invocation and collector context for both inquiry
and generation. Duplicate source ranges are included once; a whole-file attachment
supersedes source ranges from that file without removing diagnostics. Other
overlapping ranges remain separate.

Use `<C-x>` for a read-only overview of attached items and unresolved references,
not their full source contents. It opens in Normal mode; closing it returns to the
prompt.

## Sessions and responses

`<CR>` continues the selected session only when its working directory matches the
prompt invocation; otherwise it starts a new session. `<C-CR>` always starts a new
session. Continuation targets that session's explicit Pi identity, not whichever
conversation Pi last used.

Only one inquiry response can stream at a time. Navigation remains available while
it streams in the background, and completion does not change your selection. Each
session remembers its selected response; navigation stops at the boundaries rather
than wrapping. The float displays only the selected answer, not submitted prompts,
and its title identifies the session and response positions.

Closing the float preserves history. Session navigation is in memory only and does
not survive a Neovim restart, even though Pi session files remain on disk.

When focused, the response float has buffer-local controls:

| Mapping | Action | Terminal-independent fallback |
| --- | --- | --- |
| `<M-u>` / `<M-d>` | Scroll up / down | `<C-u>` / `<C-d>` |
| `[r` / `]r` | Previous / next response | |
| `[s` / `]s` | Previous / next session | |
| `q` / `<Esc>` | Close | |

By default, Psst maps global Alt-H/L to previous/next response, Alt-Shift-H/L to
previous/next session, and Alt-U/D to response scrolling. The defaults never
replace existing global keys. To define your own global policy, turn them off:

```lua
require("psst").setup({ keymaps = { global = false } })
```

Set `keymaps.float = false` to disable float-local navigation and scrolling;
`q` and `<Esc>` still close the float. The float does not override Alt-H/L or
Alt-Shift-H/L locally, so your global navigation policy applies even while it is
focused. Alt/Meta depends on terminal support; use the local fallbacks or map the
API yourself if it is not recognized.
`require("psst").float.is_visible()` reports whether the response float is in the
current tab, useful when defining your own visibility-based global mappings. The
response float can also be controlled through `require("psst").float`:

```lua
local psst = require("psst")

psst.float.focus()
psst.float.close()
psst.float.scroll("down")
psst.float.response_prev()
psst.float.response_next()
psst.float.session_prev()
psst.float.session_next()
```

Use `:PsstSessionsClear` to discard every in-memory session and response, close the
float, and recursively delete the configured `session_dir` across all working
directories. The command refuses to run while an inquiry is streaming. If deletion
fails, history and float visibility are preserved.

**`session_dir` is exclusively plugin-owned and disposable.** Never point it at
ordinary Pi sessions or any directory containing unrelated files. The directory is
recreated lazily by the next inquiry.

## Configuration

Defaults:

```lua
require("psst").setup({
    adapter = "pi",
    executable = "pi",
    model = nil, -- use Pi's configured default
    session_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "psst", "sessions"),
    float = {
        side = "right",
        width = 60,
        before_open = nil,
        after_close = nil,
    },
    keymaps = { global = true, float = true },
})
```

The float hooks receive `{ side, width }` once per hidden/visible transition, not
when selecting another response. They let a personal layout make space before the
answer opens and restore itself after the answer closes.

Use `:PsstModelSelect` to choose from the models reported by `pi --list-models`.
The list loads asynchronously during setup and is cached for the Neovim session;
run `:PsstModelsRefresh` to reload it. A picker choice applies to subsequent requests,
and `model` can also be set per request. The response float title shows the model
used for that response (`Pi default` when no model was explicitly selected).

Pi command construction and event interpretation live in `psst.adapters.pi`. Future
harnesses belong behind the same narrow boundary, but the adapter contract will grow
only from real integrations rather than hypothetical compatibility.

## Programmatic inquiries

```lua
local psst = require("psst")
local channels = require("psst.channels")
local collect = require("psst.collect")

psst.send({
    destination = channels.DESTINATION.FLOAT,
    collect = { collect.COLLECT.BLOCK, collect.COLLECT.DIAGNOSTIC },
    prompt = "What assumption am I missing here?",
})
```

## Development

With Neovim, Mise, and Just installed:

```sh
just setup
just check
```

`just check` verifies formatting and runs the tests in headless Neovim.

`just demo` records `docs/demo.gif` using VHS. The generated GIF is ignored and
should not be committed; the README uses the release-hosted demo instead.
