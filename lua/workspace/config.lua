local M = {}

M.defaults = {
    new_tab_cwd = "inherit", -- inherit | global
    buffer_scope = {
        enabled = true,
        exclude_buftypes = {
            nofile = true,
            prompt = true,
            quickfix = true,
        },
        exclude_filetypes = {},
    },
    cwd = {
        sync_global_cd = true,
    },
    tabline = {
        enabled = "auto", -- auto | true | false
        show_index = true,
        show_modified = true,
    },
    close = {
        delete_unmodified = true,
        modified = "prompt", -- prompt | keep
        notify = true,
    },
    session = {
        enabled = true,
    },
    telescope = {
        -- Load the "workspace" Telescope extension during setup when
        -- telescope.nvim is available.
        load_extension = true,
    },
    notify = vim.log.levels.WARN,
}

M.options = vim.deepcopy(M.defaults)

local function is_in_set(set, value)
    if type(set) ~= "table" then
        return false
    end
    if set[value] then
        return true
    end
    for _, item in ipairs(set) do
        if item == value then
            return true
        end
    end
    return false
end

function M.setup(overrides)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), overrides or {})

    if M.options.new_tab_cwd ~= "inherit" and M.options.new_tab_cwd ~= "global" then
        error("workspace.nvim: new_tab_cwd must be 'inherit' or 'global'")
    end

    local tabline_enabled = M.options.tabline.enabled
    if tabline_enabled ~= "auto" and type(tabline_enabled) ~= "boolean" then
        error("workspace.nvim: tabline.enabled must be 'auto', true or false")
    end

    if M.options.close.modified ~= "prompt" and M.options.close.modified ~= "keep" then
        error("workspace.nvim: close.modified must be 'prompt' or 'keep'")
    end

    if type(M.options.session.enabled) ~= "boolean" then
        error("workspace.nvim: session.enabled must be a boolean")
    end

    if type(M.options.telescope) ~= "table" or type(M.options.telescope.load_extension) ~= "boolean" then
        error("workspace.nvim: telescope.load_extension must be a boolean")
    end

    return M.options
end

function M.is_excluded_buftype(buftype)
    return is_in_set(M.options.buffer_scope.exclude_buftypes, buftype)
end

function M.is_excluded_filetype(filetype)
    return is_in_set(M.options.buffer_scope.exclude_filetypes, filetype)
end

return M
