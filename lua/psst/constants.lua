---@module "psst.constants"
---Shared constants for the Neovim agent integration.

local M = {}

M.DEFAULT_SURROUNDING_LINES = 50

M.UI = {
    FILETYPE_MARKDOWN = "markdown",
    FILETYPE_PROMPT = "psst_prompt",
    HIGHLIGHT_COMMENT = "Comment",
    STYLE_MINIMAL = "minimal",
    BORDER_ROUNDED = "rounded",
    TITLE_POS_LEFT = "left",
    READ_FLOAT = {
        ROW = 1,
        SIDE_MARGIN = 3,
        BOTTOM_MARGIN = 3,
        HEIGHT_RATIO = 2 / 3,
        BORDER_COLUMNS = 2,
        BORDER_ROWS = 2,
        ZINDEX = 49,
    },
    PROMPT = {
        MIN_ROWS = 8,
        MAX_ROWS = 20,
        MIN_WIDTH = 40,
        MAX_WIDTH = 100,
        WIDTH_RATIO = 0.7,
        HEIGHT_RATIO = 0.7,
        HORIZONTAL_MARGIN = 1,
        VERTICAL_MARGIN = 1,
        LEFT_PADDING = 1,
        BORDER_COLUMNS = 2,
        BORDER_ROWS = 2,
        ZINDEX = 50,
    },
    CONTEXT_OVERVIEW = {
        MIN_WIDTH = 40,
        MAX_WIDTH = 120,
        WIDTH_RATIO = 0.8,
        MIN_HEIGHT = 8,
        MAX_HEIGHT = 35,
        HEIGHT_RATIO = 0.7,
        HORIZONTAL_MARGIN = 1,
        VERTICAL_MARGIN = 1,
        BORDER_COLUMNS = 2,
        BORDER_ROWS = 2,
    },
}

M.NAMESPACE = {
    EDITOR = "psst_editor",
    PROMPT_FOOTER = "psst_prompt_footer",
    PROMPT_REFERENCE = "psst_prompt_reference",
}

M.AUGROUP = {
    READ_FLOAT = "PsstReadFloat",
    PROMPT = "PsstPrompt",
}

return M
