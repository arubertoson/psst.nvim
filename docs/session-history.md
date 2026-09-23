# Agent Session History

## Status

Implemented.

## Objective

Make Read interactions feel like separate conversations instead of one flat response history. Group responses by Agent Session, allow independent session and response navigation, continue the selected conversation by explicit identity, and provide one command that clears all disposable session state owned by the Neovim integration.

The response float must remain glanceable. It displays only the selected response; submitted prompts are neither retained nor rendered.

## Scope

This specification covers:

- the in-memory Agent Session and Response model;
- explicit harness session identity;
- response navigation within a session;
- navigation between sessions;
- response-float title state;
- prompt continuation behavior; and
- clearing in-memory and on-disk integration sessions.

Inline context references and context previews are separate work.

## Domain model

```lua
---@class Psst.Session
---@field id string
---@field cwd string
---@field responses Psst.Response[]
---@field response_index integer

---@class Psst.Response
---@field lines string[]
---@field label string
---@field status "streaming"|"complete"|"error"
```

The integration owns an ordered collection of sessions and one selected-session index:

```lua
---@class Psst.SessionHistory
---@field sessions Psst.Session[]
---@field session_index integer
```

### Invariants

- Every Read response belongs to exactly one Agent Session.
- Every Agent Session has one explicit harness session ID and one working directory.
- At most one Read response may be streaming at a time.
- A session's `response_index` identifies the response restored when returning to that session.
- Continue targets the Selected Session only when its working directory matches the prompt invocation working directory.
- Starting a new session creates and selects a distinct Agent Session.
- Generate never creates, selects, continues, or clears Agent Sessions.
- Submitted prompts are not stored in session history.
- Closing the response float does not remove sessions or responses.
- The Session Store is owned exclusively by this integration and is disposable.

## Session identity

Neovim must generate an explicit session ID before starting the first request in an Agent Session. The Pi harness must receive that exact identity through `--session-id` together with the configured `--session-dir`.

Subsequent requests in the same Agent Session must use the same explicit ID. They must not use `--continue`, because `--continue` identifies a session indirectly and cannot reliably resume a session selected through navigation.

Harness adapters must express explicit session identity as a capability. A harness that cannot target a session by ID cannot provide session navigation and must fail visibly rather than silently continuing another conversation.

Session identity is retained only for the lifetime of Neovim. External session files remain in the Session Store until explicitly cleared.

## Request behavior

### Read or continue: `<CR>`

When the prompt is submitted with `<CR>`:

1. If the Selected Session belongs to the invocation working directory, append a streaming Response to it and invoke the harness with that session's ID.
2. Otherwise, create and select a new Agent Session for the invocation working directory, append its first streaming Response, and invoke the harness with the new ID.
3. Select the newly appended Response.

A successful or failed harness result finalizes the Response as `complete` or `error`. Failed responses remain navigable at a glance and may contain the existing concise error line.

### New session: `<C-CR>`

When the prompt is submitted with `<C-CR>`:

1. Create a new Agent Session even when a continuable session is selected.
2. Append it to session history and select it.
3. Add and select its first streaming Response.
4. Invoke the harness with the new session's explicit ID.

A session is never created without a corresponding Read request.

### Concurrent Read requests

Starting another Read request while a Response is streaming must be rejected with a user-facing notification. The active process and response must remain unchanged.

## Navigation

### Response navigation

The Float maps response navigation locally:

| Key | Action |
| --- | --- |
| `[r` | Select the previous Response in the Selected Session |
| `]r` | Select the next Response in the Selected Session |

Navigation stops at the first and last response; it does not wrap and never crosses into another session.

### Session navigation

| Key | Action |
| --- | --- |
| `[s` | Select the previous Agent Session |
| `]s` | Select the next Agent Session |

Session navigation stops at the first and last session and does not wrap. Selecting a session restores the response identified by that session's `response_index`.

Session and response navigation remains available while a Response is streaming. Navigating away does not interrupt the active process or change the streaming Response's ownership. Streamed output continues to accumulate in that Response, and returning to it renders all output received while it was not selected. Harness completion does not change the current selection.

The Float installs buffer-local navigation mappings when open without overriding
the host's Alt-H/L or Alt-Shift-H/L keys. Global Alt mappings for navigation and
scrolling are on by default but never overwrite existing global mappings. Set
`setup({ keymaps = { global = false, float = false } })` to disable navigation keys
entirely; `q` and `<Esc>` remain local close controls. Navigation from the editor or a closed
float reopens the float at the selected target. Users can instead map the public
navigation functions themselves. `require("psst").float.focus()` restores the
currently selected response without changing either index. `require("psst").float.is_visible()`
reports whether the Float is visible in the current tab.

## Response float

The float body contains only Response lines. It does not render the request prompt, context summary, session metadata, or navigation help.

The title communicates both navigation dimensions:

```text
pi · S2/3 · R1/4
```

Where:

- `S2/3` is the Selected Session position and total session count;
- `R1/4` is the selected Response position and response count within that session; and
- `pi` is the existing harness label.

When the selected Response is streaming, the existing spinner and progress phrase follow the indices:

```text
pi · S2/3 · R1/4 · ⠋ thinking
```

When another Response is selected while streaming continues in the background, the title describes the selected Response without a spinner. Returning to the streaming Response restores its live spinner and progress phrase.

Indices are always shown, including `S1/1 · R1/1`, so the title has a stable shape.

## Prompt footer

When the Selected Session can be continued from the invocation working directory:

```text
[CR] continue S2   [^CR] new session   [^G] generate   [^P] session
```

Otherwise:

```text
[CR] read   [^CR] new session   [^G] generate   [^P] session
```

The footer does not display response counts or prompt history.

## Clearing sessions

Register one command:

```vim
:PsstSessionsClear
```

The command clears every Agent Session owned by the integration, across all working directories represented in the current Neovim process.

### Preconditions

If a Response is streaming, the command must fail visibly and make no changes. Process cancellation is outside this specification.

### Operation

The command must:

1. Count the in-memory Agent Sessions and Responses for its completion message.
2. Remove the configured Session Store recursively with `vim.fs.rm(..., { recursive = true })`.
3. If removal fails for a reason other than the directory being absent, report the error and preserve all in-memory state and float visibility.
4. Close the response float.
5. Clear all in-memory sessions and responses.
6. Reset session and response selection.
7. Invalidate all continuation state.
8. Notify with the number of cleared sessions and responses.

Example:

```text
Cleared 3 agent sessions and 14 responses
```

If both disk and memory are already empty:

```text
Agent sessions already empty
```

The Session Store is recreated lazily by the next Read request. The command takes no bang and requires no confirmation because `session_dir` is, by contract, exclusively owned and disposable.

## Ownership and lifecycle

- Session history exists only for the lifetime of Neovim.
- The configured `session_dir` is the Session Store for this integration.
- The default Session Store remains `stdpath("cache") .. "/aru/agent/sessions"`.
- Users who override `session_dir` grant the integration exclusive ownership of that directory.
- Session files created by normal Pi usage outside this directory are never read, selected, or removed.
- Restoring session navigation after restarting Neovim is out of scope.

## Implementation boundaries

### Session history

`lua/psst/session.lua` owns:

- Agent Session creation and explicit IDs;
- session and response collections;
- selected indices;
- working-directory continuation eligibility;
- session and response navigation; and
- clearing in-memory history.

It must model active state explicitly rather than representing every field as optional.

### Response channel

`lua/psst/channels/float.lua` owns:

- the volatile float window, buffer, extmarks, timers, and stream state;
- rendering the selected Response;
- saving streamed lines into the owning Response;
- float title presentation; and
- closing or restoring the float.

The float channel must not maintain a second response-history collection.

### Harness

`lua/psst/adapters/pi.lua` owns translating an explicit session ID into harness arguments. Session selection must be resolved before building the command.

### Facade and command

`lua/psst/init.lua` coordinates request submission and exposes session/response navigation and clearing through the public agent facade. It registers `:PsstSessionsClear` during setup.

## Compatibility and migration

- Replace the flat `_pages` and `_page_index` state in the float channel.
- Replace the `continuable` boolean and `last_cwd` state in the session module.
- Replace Pi `--continue` invocation for Read requests with explicit `--session-id` invocation.
- Preserve current response rendering, scrolling, lifecycle hooks, Markview rendering, and error-line behavior.
- Preserve existing Generate behavior.
- Existing session files in the dedicated Session Store need not be imported into in-memory navigation.

## Acceptance criteria

- Two new-session requests create two independently navigable Agent Sessions.
- Continuing a selected session appends a Response only to that session.
- Returning to a session restores its last selected Response.
- Response navigation never crosses a session boundary.
- Session navigation never changes a session's selected Response.
- The float body contains only the selected response.
- The title always displays accurate session and response indices.
- A session selected for another working directory is not continued accidentally.
- A second Read request is rejected while one is streaming.
- Session and response navigation remain available while streaming.
- Navigating away from a streaming Response does not interrupt it or lose output.
- Harness completion does not move the current selection.
- `:PsstSessionsClear` removes the dedicated Session Store and all in-memory history.
- `:PsstSessionsClear` leaves state unchanged when disk removal fails.
- `:PsstSessionsClear` refuses to run while streaming.
- Generate requests do not affect Agent Session history.
- Closing and restoring the float preserves both selected indices.
- The complete test suite passes via `just check`.

## Required tests

- explicit session ID command construction;
- new-session creation and selection;
- continuation of the Selected Session;
- working-directory mismatch creating a new session;
- response navigation boundaries;
- session navigation boundaries;
- per-session response-index restoration;
- title formatting for idle and streaming responses;
- rejection of concurrent Read requests;
- navigation while a non-selected Response continues streaming;
- restoration of output accumulated while the streaming Response was not selected;
- harness completion preserving the current selection;
- successful clear with existing disk and memory state;
- clear with an absent Session Store;
- failed disk removal preserving memory and float state;
- clear while streaming preserving all state; and
- isolation of Generate behavior.

## Out of scope

- Persisting or restoring navigation state across Neovim restarts.
- Discovering or importing pre-existing Pi sessions.
- Displaying submitted prompts in the response float.
- Prompt history.
- Naming, renaming, deleting, or forking individual sessions.
- Wrapping session or response navigation.
- Cancelling an active process as part of session clearing.
- Inline context references and context preview.
