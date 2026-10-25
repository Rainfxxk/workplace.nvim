local config = require("workplace.config")
local registry = require("workplace.registry")
local util = require("workplace.util")

local M = {}

local function exclusive_info(ws)
    local exclusive = registry.exclusive_buffers(ws)
    local modified = {}

    for _, buf in ipairs(exclusive) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
            modified[#modified + 1] = buf
        end
    end

    return exclusive, modified
end

local function close_tab(ws)
    if #vim.api.nvim_list_tabpages() <= 1 then
        util.notify("cannot close the last workspace", vim.log.levels.WARN)
        return false
    end

    local number = util.tab_number(ws.tab)
    if not number then
        util.notify("workspace tab is no longer valid", vim.log.levels.ERROR)
        return false
    end

    local ok, err = pcall(vim.cmd, "tabclose " .. number)
    if not ok then
        util.notify("failed to close workspace: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end

    if vim.api.nvim_tabpage_is_valid(ws.tab) then
        util.notify("workspace was not closed", vim.log.levels.WARN)
        return false
    end

    return true
end

local function start_close(ws, opts)
    opts = opts or {}

    registry.close_plans[ws.id] = {
        delete_unmodified = opts.delete_unmodified ~= false and config.options.close.delete_unmodified ~= false,
        delete_modified = opts.delete_modified == true,
        initiated = true,
    }

    local ok = close_tab(ws)
    if not ok then
        registry.close_plans[ws.id] = nil
    end
    return ok
end

local function prompt_close(ws, modified)
    local items = {
        {
            label = "Cancel",
            detail = "Keep the workspace open",
            action = "cancel",
        },
        {
            label = "Close and discard changes",
            detail = "Delete the unsaved exclusive buffers",
            action = "discard",
        },
        {
            label = "Close and keep buffers",
            detail = "Close the tab but keep modified buffers hidden",
            action = "keep",
        },
    }

    local names = {}
    for _, buf in ipairs(modified) do
        names[#names + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    end

    vim.ui.select(items, {
        prompt = string.format(
            "Workspace %s has %d unsaved exclusive buffer(s): %s. Close it?",
            ws.name,
            #modified,
            table.concat(names, ", ")
        ),
        format_item = function(item)
            return item.label .. " - " .. item.detail
        end,
    }, function(choice)
        if not choice or choice.action == "cancel" then
            return
        end
        if not vim.api.nvim_tabpage_is_valid(ws.tab) then
            return
        end

        if choice.action == "discard" then
            start_close(ws, {
                delete_modified = true,
                delete_unmodified = true,
            })
        else
            start_close(ws, {
                delete_modified = false,
                delete_unmodified = true,
            })
        end
    end)
end

--- Request closing a workspace. The plugin command can prompt before closing;
--- native :tabclose cannot be cancelled and is handled by capture()/finalize().
function M.request(ws, opts)
    opts = opts or {}
    ws = ws or registry.current()
    if not ws or not vim.api.nvim_tabpage_is_valid(ws.tab) then
        util.notify("workspace is no longer valid", vim.log.levels.ERROR)
        return
    end
    if #vim.api.nvim_list_tabpages() <= 1 then
        util.notify("cannot close the last workspace", vim.log.levels.WARN)
        return
    end
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local _, modified = exclusive_info(ws)

    if opts.force then
        start_close(ws, {
            delete_modified = true,
            delete_unmodified = true,
        })
        return
    end

    if #modified > 0 and config.options.close.modified == "prompt" then
        prompt_close(ws, modified)
        return
    end

    start_close(ws, {
        delete_modified = false,
        delete_unmodified = true,
    })
end

--- Capture close state before Neovim closes the tab (TabClosedPre).
function M.capture(tab)
    local id = registry.by_tab[tab]
    local ws = id and registry.workspaces[id]
    if not ws then
        return nil
    end

    local exclusive, modified = exclusive_info(ws)
    local plan = registry.close_plans[ws.id]
    if not plan then
        plan = {
            delete_unmodified = config.options.close.delete_unmodified ~= false,
            delete_modified = false,
            pristine = true,
        }
    end

    local capture = {
        ws_id = ws.id,
        tab = tab,
        name = ws.name,
        exclusive = exclusive,
        modified = modified,
        plan = vim.deepcopy(plan),
    }
    registry.pending_close[tab] = capture
    return capture
end

--- Remove a captured workspace and apply close policy after TabClosed.
--- This runs after the tab is gone; deletion is deferred via vim.schedule.
function M.finalize(capture)
    if not capture then
        return
    end

    registry.close_plans[capture.ws_id] = nil
    -- pending_close is already cleared by the TabClosed handler. Do not clear it
    -- here by tab handle: a new tab could theoretically reuse the handle before
    -- this scheduled cleanup runs.

    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local plan = capture.plan or {}
    local preserved = 0
    local deleted = 0
    local errors = {}

    local function preserve_as_orphan(buf)
        local previous_guard = registry.guards.scope
        registry.guards.scope = true
        pcall(function()
            vim.bo[buf].buflisted = false
        end)
        registry.guards.scope = previous_guard
        registry.remember_orphan(buf)
        preserved = preserved + 1
    end

    for _, buf in ipairs(capture.exclusive) do
        if vim.api.nvim_buf_is_valid(buf) then
            local memberships = registry.memberships[buf]
            local still_owned = memberships and next(memberships) ~= nil
            local displayed = util.buf_displayed(buf)

            if not still_owned and not displayed then
                local modified = vim.bo[buf].modified
                local should_delete = not modified or plan.delete_modified == true

                if modified and not should_delete then
                    preserve_as_orphan(buf)
                elseif not modified and plan.delete_unmodified == false then
                    preserve_as_orphan(buf)
                else
                    local ok, err = pcall(vim.api.nvim_buf_delete, buf, {
                        force = modified,
                    })
                    if ok then
                        deleted = deleted + 1
                    else
                        errors[#errors + 1] = tostring(err)
                        preserve_as_orphan(buf)
                    end
                end
            end
        end
    end

    if preserved > 0 and config.options.close.notify then
        util.notify(
            string.format(
                "closed %s; kept %d buffer(s) as hidden orphans",
                capture.name,
                preserved
            ),
            vim.log.levels.WARN
        )
    end

    if #errors > 0 then
        util.notify(
            "failed to delete some workspace buffers: " .. table.concat(errors, "; "),
            vim.log.levels.ERROR
        )
    end

    return deleted, preserved
end

return M
