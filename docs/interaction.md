# Agent Interaction

A focused Neovim integration for sending editor context and user intent to an
agent. It provides focused Read and Generate interactions without recreating an
agent chat UI inside Neovim.

## Concepts

- **Executable**: the concrete command or path, such as `pi-dev` or a local build.
- **Harness**: the CLI and streaming protocol shared by compatible executables.
- **Destination**: where a request is handled: the read Float or the Editor.
- **Agent Session**: a Read conversation owned by this integration and targeted by an explicit harness session ID.
- **Response**: the retained output of one Read request within an Agent Session.

The built-in `pi` harness can be used with any compatible executable:

```lua
require("psst").setup({
    executable = "pi-dev",
    adapter = "pi",
})
```

## Prompt

`<leader>p` opens a prompt using the current editor location. Normal mode captures
the cursor and surrounding block. Visual mode captures the selected range.

Inside the prompt:

| Key | Interaction |
| --- | --- |
| `<CR>` | Read, continuing the current session when available |
| `<C-CR>` | Read in a fresh session |
| `<C-g>` | Generate code in the Editor |
| `<M-CR>` | Insert a prompt newline |
| `<Esc>` | Cancel |

## Read

Read streams the response into a side-anchored Float without moving focus. Its
side and width are configurable:

```lua
require("psst").setup({
    float = {
        side = "right", -- "left" or "right"
        width = 80,
    },
})
```

- The first request creates an Agent Session with an explicit harness identity.
- `<CR>` continues the Selected Session when its working directory matches the
  prompt invocation; otherwise it creates a new Agent Session.
- `<C-CR>` always creates a new Agent Session.
- Agent Sessions and Responses remain navigable for the lifetime of Neovim.
- Submitted prompts are not retained or rendered.
- Only one Response can stream at a time. Navigation remains available while it
  streams in the background.

Float controls:

| Key | Action |
| --- | --- |
| `<leader>P` | Focus, unfocus, or restore the Float |
| `<M-h>` / `<M-l>` | Previous / next Response in the Selected Session |
| `<M-H>` / `<M-L>` | Previous / next Agent Session |
| `<M-u>` / `<M-d>` | Scroll up / down |
| `q` / `<Esc>` | Close while focused |

`:PsstSessionsClear` removes all in-memory Agent Sessions and the disposable
Session Store. It refuses to run while a Response is streaming.

Float visibility has `before_open` and `after_close` lifecycle hooks. They run
once per hidden/visible transition, not for Response selection changes, and receive the
resolved `{ side, width }` layout. The local no-neck-pain integration uses them
to expand the center window while the Float is visible and restore its previous
width afterward.

## Generate

Generate is a one-shot, stateless process.

- Normal mode inserts completed output at the captured cursor.
- Visual mode replaces the captured selection.
- Output is buffered and applied only after the process completes.
- The inserted result becomes the active selection, making an immediate follow-up
  Generate request operate on that result.
- Undo rejects the change using normal Neovim behavior.
- Generate does not clear or join the current Read session.

There is no generated-alternative history and no streamed ghost-code acceptance
flow. Further revisions use the current buffer as context for another one-shot
request.

## Harness support

Harness adapters are currently built in. The executable and harness are separate
so forks, wrappers, and local development builds can share a protocol. A future
standalone plugin may expose harness registration for additional agents such as
OpenCode or Claude Code.

## Intentional limits

- Agent Session navigation does not survive a Neovim restart.
- Generate has no conversational state or alternative history.
- Harness registration is not public yet.
