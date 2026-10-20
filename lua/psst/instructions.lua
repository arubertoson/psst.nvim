---@module "psst.instructions"
---Composes Psst's workflow instructions separately from the user's request.
---Caller additions supplement the defaults; generation retains its output contract.

local M = {}

local INQUIRY = [[You are answering a question inside a text editor. Help the user understand
the code or resolve the question without leaving their editing flow.

Answer the user's actual question directly. Be concise, but include the
reasoning or example needed to make the answer useful. Avoid introductions,
recaps, and unsolicited implementation plans.

Use the supplied editor context first. Inspect additional files or reference
material when needed to verify the answer. Distinguish observed behavior
from assumptions; don't invent APIs, file locations, or line numbers.

When helpful, point to the relevant file and symbol. Ask a focused question
only when missing information materially changes the answer.

This is an inquiry, not an implementation task. Do not modify files or
other persistent state.]]

local GENERATION = [[Generate code for the user's request inside a text editor.
The editor will apply your response directly to the buffer.

Return only the text to insert or replace: no Markdown fences,
explanations, labels, or surrounding commentary.

Follow the surrounding code's style, indentation, and conventions.
Use the supplied context and inspect additional sources when necessary.
Do not modify files yourself; the editor owns applying the result.]]

local INSERT = [[Return only the text to insert at the cursor. Do not repeat surrounding code.]]
local REPLACE = [[Return the complete replacement for the selected text.
Do not include code outside the selection.]]

---@param intent Psst.adapters.Intent
---@param additional string|nil Literal instructions, not a file path; empty adds nothing.
---@param selection Psst.Selection|nil Captured editor selection for generation.
---@return string
function M.render(intent, additional, selection)
    local sections = { intent == "inquire" and INQUIRY or GENERATION }
    if additional and additional ~= "" then sections[#sections + 1] = additional end
    if intent == "generate" then sections[#sections + 1] = selection and REPLACE or INSERT end
    return table.concat(sections, "\n\n")
end

return M
