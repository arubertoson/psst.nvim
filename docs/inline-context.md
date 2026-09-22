# Agent Inline Context

## Status

Proposed.

## Objective

Allow a prompt to name additional editor context inline, complete file paths and
symbols while the prompt is being written, show the context that would be sent,
and render the final request using Pi-compatible file attachments.

Inline context must remain text-driven: the current prompt text is the source of
truth. Editing, completing, invalidating, or deleting a reference must update the
attached context without maintaining a second mutable reference list.

## Scope

This specification covers:

- inline file, line-range, and symbol references;
- path and symbol completion in the agent prompt;
- reference parsing and derived reference states;
- live reference highlighting and an expanded context overview;
- reference highlighting;
- context composition and deduplication;
- submission-time resolution; and
- Pi-compatible payload rendering.

The feature applies to Read and Generate requests created through the prompt.
Agent Session and Response history remain unchanged.

## Domain model

```lua
---@alias Psst.reference.State "editing"|"resolved"|"unresolved"

---@class Psst.reference.Span
---@field start_row integer 0-based
---@field start_col integer 0-based byte offset
---@field end_row integer 0-based
---@field end_col integer 0-based exclusive byte offset

---@class Psst.reference.Reference
---@field raw string
---@field path string|nil
---@field selector Psst.reference.Selector|nil
---@field span Psst.reference.Span
---@field state Psst.reference.State
---@field error string|nil
---@field context Psst.payload.ContextItem|nil

---@class Psst.reference.LineSelector
---@field kind "lines"
---@field start_line integer
---@field end_line integer

---@class Psst.reference.SymbolSelector
---@field kind "symbol"
---@field name string

---@alias Psst.reference.Selector
---| Psst.reference.LineSelector
---| Psst.reference.SymbolSelector
```

A Reference is derived from prompt text. It is not an independently owned
object that survives text changes. A Context Item is the resolved source content
that will be attached to a request.

### Invariants

- Prompt text is the only durable source of inline references.
- Every preview refresh reparses the prompt and derives a new reference set.
- Only resolved references contribute Context Items.
- An editing or unresolved reference never leaves its previous Context Item
  attached.
- Completion acceptance does not create hidden reference state.
- Manual typing and completion acceptance produce identical results.
- Submission resolves references again against current buffer contents.
- Explicit references are combined with, not substituted for, invocation and
  collector context.
- Context rendering is independent of the selected request destination.

## Reference syntax

The supported forms are:

```text
@path
@path:start-end
@path#symbol
@#symbol
```

Examples:

```text
@lua/psst/init.lua
@lua/psst/init.lua:120-180
@lua/psst/init.lua#send
@#send
```

Paths are resolved relative to the working directory captured when the prompt
opens. `@#symbol` resolves against the invocation buffer captured when the
prompt opens.

References may be wrapped in Markdown backticks:

```text
Compare `@lua/psst/init.lua#send` with `@lua/psst/adapters/pi.lua:20-45`.
```

Backticks are delimiters and are not part of the reference.

### Lexical boundaries

A reference starts at `@` when it appears at the start of text or after
whitespace, a backtick, or opening punctuation. This prevents ordinary email
addresses from becoming references.

A reference ends at whitespace, a closing backtick, or closing prose
punctuation such as `,`, `;`, `.`, `!`, `?`, `)`, `]`, or `}`. Path separators,
periods inside a path, underscores, hyphens, and symbol punctuation such as `.`
and `::` remain part of the reference.

Paths containing unescaped whitespace and filenames ending in closing prose
punctuation are outside the initial scope. Backticks disambiguate references in
prose but do not make whitespace part of a path.

## Derived reference states

The implementation must not maintain a mutable state machine alongside the
prompt. It computes reference states from the latest prompt text and cursor
position.

### Editing

A reference is `editing` when it is incomplete, does not currently resolve, and
the cursor remains inside its span.

Examples:

```text
@lua/pss|
@lua/psst/init.lua#|
@lua/psst/init.lua#sen|
@lua/psst/init.lua:120-|
```

An editing reference contributes no Context Item and is not presented as an
error.

### Resolved

A reference is `resolved` when it identifies exactly one file, valid range, or
symbol. Resolution does not require the cursor to leave the reference.

Examples:

```text
@lua/psst/init.lua
@lua/psst/init.lua#send
@lua/psst/init.lua:120-180
```

A resolved reference contributes one Context Item.

### Unresolved

A reference is `unresolved` when it cannot resolve and the cursor is no longer
inside it, or when its syntax is complete but invalid.

Examples include a missing file, a missing or ambiguous symbol, a reversed line
range, and a range outside the target buffer.

An unresolved reference contributes no Context Item. The preview displays it
with a `?` marker and submission is refused with a concise notification naming
the first unresolved reference.

### Concrete transitions

Given this sequence:

```text
@lua/pss
@lua/psst/init.lua
@lua/psst/init.lua#
@lua/psst/init.lua#send
@lua/psst/init.lua#sen
```

The derived states and context are:

| Text | State | Attached explicit context |
| --- | --- | --- |
| `@lua/pss` while editing | editing | none |
| `@lua/psst/init.lua` | resolved | whole file |
| `@lua/psst/init.lua#` | editing | none |
| `@lua/psst/init.lua#send` | resolved | symbol range |
| `@lua/psst/init.lua#sen` while editing | editing | none |
| `@lua/psst/init.lua#sen` after leaving it | unresolved | none |
| reference deleted | absent from parse result | none |

Adding `#` or `:` to a resolved whole-file reference immediately removes the
whole-file Context Item until the new selector resolves. Deleting a reference
removes its Context Item on the next refresh.

## Resolution

Resolution is the shared operation used by completion, preview, and submission.
There is no separate validation subsystem.

### Buffer choice

When a referenced path already has a loaded Neovim buffer, resolution reads that
buffer, including unsaved changes. Otherwise it loads the file into a hidden
buffer. This keeps context consistent with what the user currently sees in the
editor.

Missing external files are expected unresolved outcomes. Internal failures to
read a valid loaded buffer are errors and must surface visibly.

### Files

A path without a selector resolves to the complete buffer contents. Directories
do not resolve as Context Items.

### Line ranges

A range resolves when:

- both endpoints are positive integers;
- `start_line <= end_line`; and
- `end_line` does not exceed the current buffer line count.

The resulting Context Item contains exactly that inclusive range.

### Symbols

Symbols are indexed from Treesitter named nodes representing functions, methods,
classes, and declarations. The resolver obtains each candidate's name and outer
node range.

An exact unique name resolves to that node's complete outer range. No match is
unresolved. Multiple exact matches are ambiguous and unresolved; candidates must
remain distinguishable in completion by line range.

The initial implementation uses Treesitter only. LSP document symbols and
language-specific fallback scanners are outside scope.

Symbol indexes may be cached by buffer number and `changedtick`. A changed tick
invalidates the cache.

## Completion

Completion is prompt-specific and uses the same resolver data as preview.

### Path completion

Typing `@` opens fuzzy project-wide file completion, including hidden files.
Matches may come from any directory depth.

Selecting a file inserts only its relative path after `@`.

### Symbol completion

Typing `#` after a resolvable file path switches to a symbol provider:

```text
@lua/psst/init.lua#
```

Candidates include their kind and range:

```text
send                    Function   126-174
prompt                  Function   180-188
PromptOpts              Class       46-49
resolve_session_policy  Function   115-122
```

Accepting a candidate inserts its symbol name. `@#` performs the same completion
against the invocation buffer.

The symbol provider returns no candidates until its file prefix resolves.

### Completion mappings

The prompt must preserve Blink navigation while its menu is visible:

- `<C-n>` selects the next item;
- `<C-p>` selects the previous item; and
- the existing smart-accept mapping accepts the selected item.

No line-number completion is required after `:`.

## Live reference feedback

The prompt owns one debounced preview refresh. `TextChanged` and `TextChangedI`
schedule a refresh after 75–100 ms. A newer text change supersedes the pending
refresh.

Completion acceptance and moving the cursor out of a reference request an
immediate refresh. Submission bypasses the debounce and resolves synchronously.

The reference refresh must be side-effect-free from the user's perspective: it
must not notify for an absent optional diagnostic, move windows, change the
cursor, or submit a process.

### Action footer

The prompt displays only its highlighted actions, right-aligned at the bottom:

```text
<editable prompt text>

                                                [CR] read   [^CR] new session   [^G] generate   [^X] overview
```

Inline References remain visible in the prompt itself. The prompt does not
repeat derived context in a summary row; `<C-x>` owns further context inspection.

### Inline highlights

Prompt-owned extmarks decorate complete reference spans:

- resolved: a subtle link or special highlight;
- editing: `Comment`;
- unresolved: `DiagnosticError`.

Extmarks are cleared and rebuilt from the latest parse result. They do not own
reference identity or context state.

### Context overview

The prompt provides `<C-x>` to inspect an expanded overview of the context that
would be attached. It opens a read-only temporary window listing Context Items
in request order without displaying their source contents or duplicating the
prompt text.

Editing and unresolved references appear in a separate section with their state
and concise resolution error when available.

The overview opens in Normal mode for cursor navigation. Closing it returns focus
to the existing prompt without changing its text or derived context.

## Context composition

A request combines context in this order:

1. invocation context, such as visual selection, enclosing block, or surrounding
   lines;
2. explicitly requested collectors, such as a diagnostic; and
3. resolved inline references in textual order.

Context Items with the same normalized path, start line, and end line are
included once. Overlapping but non-identical ranges are retained because they
may represent distinct user intent. A whole-file item does not silently remove
an explicitly named symbol or range.

Reference text remains in the user prompt. Attachments provide source content;
the references preserve the user's explanation of how that content should be
used.

## Payload rendering

Pi's native `@file` processing renders text files as:

```xml
<file name="/absolute/path">
contents
</file>
```

Source Context Items must follow that convention.

### Whole file

```xml
<file name="/absolute/path/to/agent.lua">
...
</file>
```

### Line range

```xml
<file name="/absolute/path/to/agent.lua" lines="120-180">
...
</file>
```

### Symbol

```xml
<file name="/absolute/path/to/agent.lua" symbol="send" lines="126-174">
...
</file>
```

The optional `lines` and `symbol` attributes are a conservative extension of
Pi's file format. Consumers may treat every block as ordinary named file content
without understanding those attributes.

Attribute values must be escaped. Source context blocks precede the original
prompt, matching Pi's native initial-message ordering:

```xml
<file name="/project/lua/psst/init.lua" symbol="send" lines="126-174">
...
</file>

Compare @lua/psst/init.lua#send with the current implementation.
```

Non-source context, such as diagnostics, retains a distinct descriptive tag.
The renderer must not depend on a model interpreting XML as a strict schema.

## Submission

Submitting with `<CR>`, `<C-CR>`, or `<C-g>` performs an authoritative
synchronous context build:

1. Parse the current prompt.
2. Resolve every reference against current buffer contents.
3. Refuse submission if any reference is unresolved.
4. Resolve invocation and requested collector context.
5. Combine and deduplicate Context Items.
6. Render source items as Pi-compatible file blocks before the prompt.
7. Send the result through the selected destination's existing path.

An editing reference under the cursor is unresolved for submission. The
notification names the reference and does not mutate or close the prompt.

## Ownership and lifecycle

- The prompt session owns its debounce timer, reference extmark namespace, and
  context-overview window.
- Closing the prompt stops and closes its timer, clears its extmarks, and closes
  its context overview.
- Hidden buffers loaded solely for reference resolution remain subject to the
  existing buffer-cache policy.
- Reference and symbol caches contain derived data only and may be discarded at
  any time.
- No reference or preview state survives closing the prompt.

## Implementation boundaries

### Reference parser

`lua/psst/reference.lua` owns syntax recognition, lexical spans, selector
parsing, and derived editing versus unresolved classification.

### Context resolver

`lua/psst/context.lua` owns path normalization, buffer acquisition, file and
range extraction, Treesitter symbol indexing, resolution outcomes, context
composition, and exact-range deduplication.

### File and symbol completion

`lua/psst/completion/files.lua` adapts project-wide file candidates to
Blink completion items. `lua/psst/completion/symbol.lua` adapts resolved
symbol candidates and must use the context resolver's symbol index rather than
implementing a second symbol scanner.

### Prompt

`lua/psst/prompt.lua` owns debounce lifecycle, cursor-aware refresh,
reference extmarks, action-footer rendering, expanded context-overview
presentation, and submission refusal without closing the prompt.

### Payload

`lua/psst/payload.lua` owns escaping and rendering typed Context Items. It
must render source context before prompt text and match Pi's whole-file format.

## Acceptance criteria

- Typing `@` opens project-relative path completion.
- A completed file reference is highlighted as resolved without leaving the
  reference.
- Adding `#` or `:` removes the former whole-file context until the selector
  resolves.
- Symbol completion after `#` lists Treesitter symbols from the referenced file.
- `@#symbol` resolves against the invocation buffer.
- File, symbol, and range references read unsaved loaded-buffer contents.
- Editing a resolved reference immediately removes stale context.
- Deleting a reference removes its context and highlight.
- An incomplete reference under the cursor is shown as editing, not as an error.
- Leaving an incomplete reference makes it unresolved.
- An unresolved reference prevents submission without closing the prompt.
- The prompt does not duplicate context in an inline summary.
- `<C-x>` shows a concise context overview in Normal mode and returns to the
  prompt when closed.
- Explicit references combine with invocation and diagnostic context.
- Exact duplicate ranges are rendered once.
- Whole files use Pi's native `<file name="...">` representation.
- Range and symbol source context use `<file>` with metadata attributes.
- Context blocks precede the unchanged user prompt.
- Read and Generate receive the same composed context.
- Closing the prompt releases all prompt-owned resources.
- The complete test suite passes via `just check`.

## Required tests

- lexical parsing for all four reference forms;
- reference boundaries in prose and Markdown backticks;
- cursor-aware editing versus unresolved classification;
- transition from whole file to incomplete and resolved symbol selectors;
- deletion removing derived context;
- relative path and current-file symbol resolution;
- valid, reversed, incomplete, and out-of-bounds ranges;
- exact, missing, and ambiguous symbols;
- symbol-cache invalidation by `changedtick`;
- unsaved loaded-buffer content winning over disk content;
- path and symbol completion candidates;
- `<C-p>` completion navigation;
- debounced refresh supersession and cleanup;
- right-aligned action footer rendering;
- reference extmark replacement;
- expanded context overview contents, Normal mode, and lifecycle;
- context ordering and exact-range deduplication;
- Pi-compatible whole-file rendering;
- range and symbol metadata rendering with escaped attributes;
- submission refusal preserving prompt state;
- authoritative re-resolution after a referenced buffer changes; and
- identical context composition for Read and Generate destinations.

## Out of scope

- Directory attachments.
- Paths containing whitespace.
- LSP document-symbol fallback.
- Cross-file symbol search without an explicit path.
- Symbol references that intentionally select multiple overloads.
- Automatic token budgeting, whole-file size limits, or truncation.
- Persisting prompt text, references, or preview state.
- Restoring inline references across Neovim restarts.
- Images or other binary attachments.
- Changing Agent Session or Response navigation.
