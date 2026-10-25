local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values

local M = {}

local function buffer_lines(ws)
    local lines = {}
    for _, buf in ipairs(ws.buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            name = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":~:.")
            local marker = vim.bo[buf].modified and " [+]" or ""
            lines[#lines + 1] = string.format("  %d %s%s", buf, name, marker)
        end
    end
    if #lines == 0 then
        lines[1] = "  (no buffers)"
    end
    return lines
end

local function workspace_entries()
    if not vim.g.loaded_workplace_nvim then
        vim.notify("workplace.nvim: call require('workplace').setup() first", vim.log.levels.WARN)
        return {}
    end

    local workplace = require("workplace")
    local current = workplace.current()
    local entries = {}

    for index, ws in ipairs(workplace.list()) do
        local tab = vim.api.nvim_tabpage_get_number(ws.tab)
        local cwd = vim.fn.fnamemodify(ws.cwd, ":~")
        local is_current = current ~= nil and current.id == ws.id
        local marker = is_current and "●" or "○"

        entries[#entries + 1] = {
            ws = ws,
            tab = tab,
            index = index,
            display = string.format(
                "%s %s  %s  [tab %d, %d buffers]",
                marker,
                ws.name,
                cwd,
                tab,
                #ws.buffers
            ),
            ordinal = string.format("%s %s %s", ws.name, cwd, ws.id),
        }
    end

    return entries
end

local function switch_workspace(prompt_bufnr)
    local selection = action_state.get_selected_entry()
    if not selection or not selection.value then
        return
    end

    actions.close(prompt_bufnr)
    require("workplace").switch(selection.value)
end

function M.workplace(opts)
    opts = opts or {}
    local entries = workspace_entries()
    if #entries == 0 then
        return
    end

    pickers.new(opts, {
        prompt_title = "Workplaces",
        finder = finders.new_table({
            results = entries,
            entry_maker = function(entry)
                return {
                    value = entry.ws,
                    display = entry.display,
                    ordinal = entry.ordinal,
                    tab = entry.tab,
                }
            end,
        }),
        sorter = conf.generic_sorter(opts),
        previewer = previewers.new_buffer_previewer({
            title = "Workspace",
            define_preview = function(self, entry)
                local ws = entry.value
                if not ws then
                    return
                end
                local lines = {
                    "# " .. ws.name,
                    "",
                    "cwd: `" .. ws.cwd .. "`",
                    "tab: " .. tostring(entry.tab),
                    "id: `" .. ws.id .. "`",
                    "",
                    "## Buffers",
                }
                vim.list_extend(lines, buffer_lines(ws))
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                vim.bo[self.state.bufnr].filetype = "markdown"
            end,
        }),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                switch_workspace(prompt_bufnr)
            end)
            return true
        end,
    }):find()
end

M.workspaces = M.workplace

return {
    exports = {
        workplace = M.workplace,
        workspaces = M.workspaces,
    },
}
