local root = vim.fn.getcwd()
vim.opt.rtp:append(root)

local failures = {}

local function fail(message)
    failures[#failures + 1] = message
    io.stdout:write("FAIL: " .. message .. "\n")
end

local function ok(condition, message)
    if not condition then
        fail(message)
    end
end

local function eq(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s (expected %s, got %s)", message, vim.inspect(expected), vim.inspect(actual)))
    end
end

local function has(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function wait_for(predicate, message)
    local completed = vim.wait(2000, predicate, 10)
    ok(completed, message or "condition was not met")
end

local function listed_files()
    local result = {}
    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
        if info.name ~= "" then
            result[#result + 1] = vim.fs.normalize(info.name)
        end
    end
    return result
end

local function contains(list, value)
    local normalized = vim.fs.normalize(value)
    for _, item in ipairs(list) do
        if item == normalized then
            return true
        end
    end
    return false
end

local function find_named(list, name)
    for _, item in ipairs(list) do
        if item.name == name then
            return item
        end
    end
    return nil
end

local function with_select(label, fn)
    local old_select = vim.ui.select
    vim.ui.select = function(items, _, callback)
        local picked
        for _, item in ipairs(items) do
            if item.label == label then
                picked = item
                break
            end
        end
        callback(picked)
    end
    local ok_run, err = pcall(fn)
    vim.ui.select = old_select
    ok(ok_run, "close command failed: " .. tostring(err))
end

local test_root = vim.fn.tempname()
for _, name in ipairs({
    "a",
    "b",
    "c",
    "d",
    "e",
    "m",
    "n",
    "cwd2",
    "lcd",
    "inactive",
    "noncurrent",
    "session",
    "order",
    "persist_one",
    "persist_two",
}) do
    vim.fn.mkdir(test_root .. "/" .. name, "p")
end

local function file(name)
    local path = test_root .. "/" .. name .. ".txt"
    vim.fn.writefile({ name }, path)
    return vim.fs.normalize(path)
end

local dir_a = vim.fs.normalize(test_root .. "/a")
local dir_b = vim.fs.normalize(test_root .. "/b")
local dir_c = vim.fs.normalize(test_root .. "/c")
local dir_d = vim.fs.normalize(test_root .. "/d")
local dir_e = vim.fs.normalize(test_root .. "/e")
local dir_m = vim.fs.normalize(test_root .. "/m")
local dir_n = vim.fs.normalize(test_root .. "/n")
local dir_cwd2 = vim.fs.normalize(test_root .. "/cwd2")
local dir_lcd = vim.fs.normalize(test_root .. "/lcd")
local dir_inactive = vim.fs.normalize(test_root .. "/inactive")
local dir_noncurrent = vim.fs.normalize(test_root .. "/noncurrent")
local dir_session = vim.fs.normalize(test_root .. "/session")
local dir_order = vim.fs.normalize(test_root .. "/order")
local dir_persist_one = vim.fs.normalize(test_root .. "/persist_one")
local dir_persist_two = vim.fs.normalize(test_root .. "/persist_two")

local file_a = file("a")
local file_b = file("b")
local file_c = file("c")
local file_d = file("d")
local file_e = file("e")
local file_m = file("m")
local file_n = file("n")
local file_native = file("native")
local file_delete = file("delete_me")
local file_session = file("session_file")
local file_persist_a = file("persist_a")
local file_persist_hidden = file("persist_hidden")
local file_persist_b = file("persist_b")

vim.o.hidden = true

local suite_ok, suite_err = pcall(function()
    local workspace = require("workspace")
    local registry = require("workspace.registry")

    workspace.setup({
        tabline = { enabled = false },
        close = { notify = false },
        notify = false,
    })

    local initial = workspace.current()
    ok(initial ~= nil, "initial workspace exists")
    eq(initial.cwd, vim.fs.normalize(root), "initial cwd")
    eq(vim.fn.haslocaldir(-1, vim.fn.tabpagenr()), 1, "initial tab has explicit tcd")
    ok(initial.id and initial.id ~= "", "initial workspace has an id")

    local record = vim.api.nvim_tabpage_get_var(initial.tab, registry.VAR)
    eq(record.id, initial.id, "tabpage record has the workspace id")
    eq(vim.api.nvim_tabpage_get_var(initial.tab, "name"), initial.name, "t:name is set")

    local ws_a = workspace.new({ cwd = dir_a, name = "A" })
    ok(ws_a ~= nil, "workspace A created")
    eq(workspace.current().id, ws_a.id, "new workspace is current")
    eq(vim.fn.getcwd(), dir_a, "workspace A cwd is active")
    vim.cmd("edit " .. vim.fn.fnameescape(file_a))
    local buf_a = vim.fn.bufnr("%")
    ok(has(workspace.buffers(ws_a), buf_a), "file A belongs to workspace A")

    local ws_b = workspace.new({ cwd = dir_b, name = "B" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_b))
    local buf_b = vim.fn.bufnr("%")

    local listed_b = listed_files()
    ok(contains(listed_b, file_b), "file B is listed in workspace B")
    ok(not contains(listed_b, file_a), "file A is unlisted in workspace B")

    workspace.switch(ws_a)
    local listed_a = listed_files()
    ok(contains(listed_a, file_a), "file A is listed again in workspace A")
    ok(not contains(listed_a, file_b), "file B is unlisted in workspace A")

    workspace.switch(ws_b)
    vim.cmd("edit " .. vim.fn.fnameescape(file_a))
    ok(has(workspace.buffers(ws_b), buf_a), "shared file A belongs to workspace B")
    workspace.switch(ws_a)
    ok(has(workspace.buffers(ws_a), buf_a), "shared file A still belongs to workspace A")

    workspace.set_cwd(ws_a, dir_cwd2)
    eq(vim.fn.getcwd(), dir_cwd2, "set_cwd changes effective cwd")
    eq(workspace.cwd(ws_a), dir_cwd2, "set_cwd updates the workspace cwd")
    workspace.switch(ws_b)
    eq(vim.fn.getcwd(), dir_b, "workspace B cwd is preserved")
    workspace.switch(ws_a)
    eq(vim.fn.getcwd(), dir_cwd2, "workspace A cwd is restored")

    vim.cmd("cd " .. vim.fn.fnameescape(dir_lcd))
    eq(workspace.cwd(ws_a), dir_lcd, ":cd is written back to the workspace")
    ok(vim.fn.haslocaldir(-1, vim.fn.tabpagenr()) == 1, ":cd keeps a tab-local cwd")

    local cwd_before_lcd = workspace.cwd(ws_a)
    vim.cmd("lcd " .. vim.fn.fnameescape(dir_c))
    eq(workspace.cwd(ws_a), cwd_before_lcd, ":lcd does not change workspace cwd")

    vim.cmd("tcd " .. vim.fn.fnameescape(dir_a))
    workspace.set_cwd(ws_a, dir_a)

    local tabline = require("workspace.tabline").render()
    ok(type(tabline) == "string" and #tabline > 0, "tabline renderer returns a string")
    ok(tabline:find("A", 1, true) ~= nil, "tabline contains workspace name")

    local ws_c = workspace.new({ cwd = dir_c, name = "C" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_c))
    local buf_c = vim.fn.bufnr("%")
    local tabs_before = #vim.api.nvim_list_tabpages()
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before - 1
    end, "unmodified workspace closed")
    wait_for(function()
        return not vim.api.nvim_buf_is_valid(buf_c)
    end, "unmodified exclusive buffer deleted")
    ok(workspace.find("C") == nil, "closed workspace is removed")

    workspace.switch(ws_b)
    local tabs_before_shared = #vim.api.nvim_list_tabpages()
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_shared - 1
    end, "shared-buffer workspace closed")
    wait_for(function()
        return not vim.api.nvim_buf_is_valid(buf_b)
    end, "exclusive buffer of workspace B was deleted")
    ok(vim.api.nvim_buf_is_valid(buf_a), "shared buffer survived workspace close")
    ok(workspace.find("B") == nil, "workspace B is removed")

    local ws_m = workspace.new({ cwd = dir_m, name = "M" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_m))
    local buf_m = vim.fn.bufnr("%")
    vim.api.nvim_buf_set_lines(buf_m, 0, -1, false, { "modified" })
    with_select("Close and keep buffers", function()
        vim.cmd("WorkspaceClose")
    end)
    wait_for(function()
        return workspace.find("M") == nil
    end, "modified-keep close completed")
    wait_for(function()
        return vim.api.nvim_buf_is_valid(buf_m) and not vim.bo[buf_m].buflisted
    end, "modified buffer preserved as hidden")
    ok(vim.bo[buf_m].modified, "preserved buffer still has unsaved changes")

    local ws_d = workspace.new({ cwd = dir_d, name = "D" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_d))
    local buf_d = vim.fn.bufnr("%")
    vim.api.nvim_buf_set_lines(buf_d, 0, -1, false, { "modified" })
    with_select("Close and discard changes", function()
        vim.cmd("WorkspaceClose")
    end)
    wait_for(function()
        return not vim.api.nvim_buf_is_valid(buf_d)
    end, "discarded modified buffer was deleted")
    ok(workspace.find("D") == nil, "discarding workspace was removed")

    local ws_e = workspace.new({ cwd = dir_e, name = "E" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_e))
    local buf_e = vim.fn.bufnr("%")
    vim.api.nvim_buf_set_lines(buf_e, 0, -1, false, { "modified" })
    with_select("Cancel", function()
        vim.cmd("WorkspaceClose")
    end)
    ok(workspace.find("E") ~= nil, "cancel keeps the workspace")
    workspace.close(ws_e, { force = true })
    wait_for(function()
        return workspace.find("E") == nil
    end, "forced close completed")

    local ws_n = workspace.new({ cwd = dir_n, name = "N" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_n))
    local buf_n = vim.fn.bufnr("%")
    vim.api.nvim_buf_set_lines(buf_n, 0, -1, false, { "modified" })
    local tabs_before_native = #vim.api.nvim_list_tabpages()
    local native_ok, native_err = pcall(vim.cmd, "tabclose")
    ok(native_ok, "native tabclose with modified buffer: " .. tostring(native_err))
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_native - 1
    end, "native close removed the tab")
    wait_for(function()
        return vim.api.nvim_buf_is_valid(buf_n) and not vim.bo[buf_n].buflisted
    end, "native close preserved modified buffer")
    ok(workspace.find("N") == nil, "native close removed workspace N")

    local workspace_before_native_tab = workspace.current()
    local tabs_before_native_tab = #vim.api.nvim_list_tabpages()
    vim.cmd("tabnew " .. vim.fn.fnameescape(file_native))
    local native_ws = workspace.current()
    local native_buf = vim.fn.bufnr("%")
    ok(native_ws.id ~= workspace_before_native_tab.id, "native :tabnew creates a new workspace")
    ok(has(native_ws.buffers, native_buf), "native :tabnew attaches its file")
    ok(not has(native_ws.buffers, buf_a), "native :tabnew does not inherit the old workspace buffer")
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_native_tab
    end, "native-created workspace closed")

    local active_before_inactive = workspace.current()
    local inactive = workspace.new({ cwd = dir_inactive, name = "Inactive", enter = false })
    ok(inactive ~= nil, "inactive workspace created")
    eq(workspace.current().id, active_before_inactive.id, "enter=false keeps the active workspace")
    local inactive_number = require("workspace.util").tab_number(inactive.tab)
    eq(vim.fn.getcwd(-1, inactive_number), dir_inactive, "inactive workspace has its own tab cwd")
    for _, buf in ipairs(workspace.buffers(inactive)) do
        ok(not vim.bo[buf].buflisted, "inactive workspace buffer is unlisted")
        ok(not has(workspace.buffers(active_before_inactive), buf), "inactive buffer is not leaked into the active workspace")
    end
    workspace.switch(inactive)
    eq(vim.fn.getcwd(), dir_inactive, "inactive workspace cwd becomes active when entered")
    local tabs_before_inactive_close = #vim.api.nvim_list_tabpages()
    workspace.close(inactive, { force = true })
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_inactive_close - 1
    end, "inactive workspace closed")

    local shared_owner = workspace.current()
    local shared_buffer = vim.api.nvim_get_current_buf()
    local tabs_before_split = #vim.api.nvim_list_tabpages()
    vim.cmd("tab split")
    local split_ws = workspace.current()
    ok(split_ws.id ~= shared_owner.id, ":tab split creates a new workspace")
    ok(has(workspace.buffers(split_ws), shared_buffer), ":tab split shares the current buffer")
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_split
    end, "tab-split workspace closed")
    ok(vim.api.nvim_buf_is_valid(shared_buffer), "shared buffer survives tab-split close")

    local delete_ws = workspace.current()
    vim.cmd("edit " .. vim.fn.fnameescape(file_delete))
    local delete_buf = vim.fn.bufnr("%")
    ok(has(workspace.buffers(delete_ws), delete_buf), "buffer opened for bdelete is attached")
    vim.cmd("bdelete " .. delete_buf)
    ok(not has(workspace.buffers(delete_ws), delete_buf), ":bdelete removes buffer membership")

    local active_before_noncurrent = workspace.current()
    local tabs_before_noncurrent = #vim.api.nvim_list_tabpages()
    local noncurrent = workspace.new({ cwd = dir_noncurrent, name = "NonCurrent", enter = false })
    local noncurrent_buf = workspace.buffers(noncurrent)[1]
    workspace.close(noncurrent, { force = true })
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_noncurrent
    end, "non-current workspace closed")
    ok(workspace.find("NonCurrent") == nil, "non-current workspace removed")
    eq(workspace.current().id, active_before_noncurrent.id, "active workspace unchanged after non-current close")
    if noncurrent_buf then
        wait_for(function()
            return not vim.api.nvim_buf_is_valid(noncurrent_buf)
        end, "exclusive buffer of non-current workspace deleted")
    end

    local tabs_before_command = #vim.api.nvim_list_tabpages()
    vim.cmd("Workspace new " .. vim.fn.fnameescape(dir_inactive) .. " CmdWorkspace")
    local command_ws = workspace.find("CmdWorkspace")
    ok(command_ws ~= nil, ":Workspace new creates a named workspace")
    vim.cmd("Workspace rename RenamedByCommand")
    eq(workspace.current().name, "RenamedByCommand", ":Workspace rename updates the name")
    local list_ok, list_err = pcall(vim.cmd, "Workspace list")
    ok(list_ok, ":Workspace list runs: " .. tostring(list_err))
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_command
    end, ":WorkspaceClose closed the command-created workspace")

    local reorder = workspace.new({ cwd = dir_order, name = "Reorder" })
    local reorder_tab = reorder.tab
    vim.cmd("tabmove 0")
    ok(vim.api.nvim_tabpage_is_valid(reorder_tab), "workspace tab stays valid after :tabmove")
    eq(registry.by_tab[reorder_tab], reorder.id, "workspace mapping survives :tabmove")
    eq(workspace.current().id, reorder.id, "reordered workspace remains current")
    eq(vim.api.nvim_tabpage_get_var(reorder_tab, registry.VAR).id, reorder.id, "t: record survives :tabmove")
    local tabs_before_reorder_close = #vim.api.nvim_list_tabpages()
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_reorder_close - 1
    end, "reordered workspace closed")

    local owner = workspace.current()
    local moved_buffer = vim.api.nvim_get_current_buf()
    vim.cmd("split")
    local tabs_before_window_move = #vim.api.nvim_list_tabpages()
    vim.cmd("wincmd T")
    local moved_ws = workspace.current()
    ok(moved_ws.id ~= owner.id, "<C-w>T creates a new workspace")
    wait_for(function()
        return has(workspace.buffers(moved_ws), moved_buffer)
    end, "<C-w>T workspace receives the moved buffer")
    ok(has(workspace.buffers(owner), moved_buffer), "moved buffer remains owned by the original workspace")
    vim.cmd("WorkspaceClose")
    wait_for(function()
        return #vim.api.nvim_list_tabpages() == tabs_before_window_move
    end, "window-move workspace closed")
    ok(vim.api.nvim_buf_is_valid(moved_buffer), "shared buffer survives closing the moved workspace")
    pcall(vim.cmd, "silent only")

    workspace.new({ cwd = dir_session, name = "SessionSafe" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_session))
    local session_buf = vim.fn.bufnr("%")
    vim.api.nvim_exec_autocmds("SessionLoadPre", {})
    vim.cmd("tabclose")
    vim.api.nvim_exec_autocmds("SessionLoadPost", {})
    wait_for(function()
        return #workspace.list() == #vim.api.nvim_list_tabpages()
    end, "session load rebuilt the registry")
    ok(vim.api.nvim_buf_is_valid(session_buf), "session load did not delete workspace buffers")

    local persist_one = workspace.new({ cwd = dir_persist_one, name = "PersistOne" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_persist_a))
    local persist_a_buf = vim.fn.bufnr("%")
    vim.cmd("vsplit " .. vim.fn.fnameescape(file_persist_hidden))
    local persist_hidden_buf = vim.fn.bufnr("%")
    vim.cmd("close")
    ok(has(workspace.buffers(persist_one), persist_a_buf), "persist workspace has its first buffer")
    ok(has(workspace.buffers(persist_one), persist_hidden_buf), "persist workspace has its hidden buffer")

    workspace.new({ cwd = dir_persist_two, name = "PersistTwo" })
    vim.cmd("edit " .. vim.fn.fnameescape(file_persist_b))
    local persist_b_buf = vim.fn.bufnr("%")

    ok(vim.api.nvim_buf_is_valid(persist_hidden_buf), "hidden buffer stays valid before session save")
    eq(#vim.fn.win_findbuf(persist_hidden_buf), 0, "hidden buffer has no window")
    ok(not vim.bo[persist_hidden_buf].buflisted, "hidden buffer is unlisted before session save")
    ok(has(workspace.buffers(persist_one), persist_hidden_buf), "hidden buffer membership survives unlisting")

    local session_file = vim.fs.normalize(test_root .. "/roundtrip.vim")
    -- Save a session without curdir: mksession will omit all tcd commands, so
    -- restoring the per-workspace cwd must come from the sidecar.
    local original_sessionoptions = vim.o.sessionoptions
    local session_option_list = vim.split(original_sessionoptions, ",", { trimempty = true })
    session_option_list = vim.tbl_filter(function(option)
        return option ~= "curdir"
    end, session_option_list)
    vim.o.sessionoptions = table.concat(session_option_list, ",")
    vim.cmd("mksession! " .. vim.fn.fnameescape(session_file))
    vim.o.sessionoptions = original_sessionoptions

    local session_text = table.concat(vim.fn.readfile(session_file), "\n")
    ok(not session_text:find("tcd", 1, true), "test session intentionally has no tcd commands")

    local session_module = require("workspace.session")
    local sidecar = session_module.sidecar_path(session_file)
    ok(sidecar ~= nil and vim.fn.filereadable(sidecar) == 1, "mksession writes a workspace sidecar")

    local snapshot = session_module.read(session_file)
    ok(snapshot ~= nil, "workspace sidecar is readable")
    if snapshot then
        local snap_one = find_named(snapshot.workspaces, "PersistOne")
        local snap_two = find_named(snapshot.workspaces, "PersistTwo")
        ok(snap_one ~= nil, "sidecar contains PersistOne")
        ok(snap_two ~= nil, "sidecar contains PersistTwo")
        if snap_one then
            eq(vim.fs.normalize(snap_one.cwd), dir_persist_one, "sidecar stores PersistOne cwd")
            ok(contains(snap_one.buffers, file_persist_a), "sidecar stores the visible persist buffer")
            ok(contains(snap_one.buffers, file_persist_hidden), "sidecar stores the hidden persist buffer")
            eq(vim.fs.normalize(snap_one.active_buffer), vim.fs.normalize(file_persist_a), "sidecar stores the active buffer")
        end
        if snap_two then
            eq(vim.fs.normalize(snap_two.cwd), dir_persist_two, "sidecar stores PersistTwo cwd")
            ok(contains(snap_two.buffers, file_persist_b), "sidecar stores PersistTwo buffer")
        end
    end

    local checker = vim.fs.normalize(root .. "/tests/session_child.lua")
    local child = vim.system({
        vim.v.progpath,
        "--headless",
        "--clean",
        "-u",
        "NONE",
        "--cmd",
        "set hidden",
        "--cmd",
        "set rtp+=" .. root,
        "--cmd",
        "lua require('workspace').setup({tabline={enabled=false},notify=false,close={notify=false}})",
        "-S",
        session_file,
        "-c",
        "luafile " .. checker,
    }, { text = true }):wait(20000)

    ok(child.code == 0, "session restore child exited successfully: " .. tostring(child.stderr))
    local encoded = child.stdout and child.stdout:match("WORKSPACE_RESULT:([^\n]+)")
    ok(encoded ~= nil, "session restore child returned a result")
    if encoded then
        local decoded_ok, result = pcall(vim.json.decode, encoded)
        ok(decoded_ok, "session restore result is valid JSON")
        if decoded_ok and result then
            local p1 = find_named(result.workspaces, "PersistOne")
            local p2 = find_named(result.workspaces, "PersistTwo")
            ok(p1 ~= nil, "restored PersistOne workspace")
            ok(p2 ~= nil, "restored PersistTwo workspace")

            if p1 then
                eq(vim.fs.normalize(p1.cwd), dir_persist_one, "restored PersistOne cwd")
                ok(contains(p1.files, file_persist_a), "restored PersistOne visible buffer")
                ok(contains(p1.files, file_persist_hidden), "restored PersistOne hidden buffer")
                eq(vim.fs.normalize(p1.active), vim.fs.normalize(file_persist_a), "restored PersistOne active buffer")
            end
            if p2 then
                eq(vim.fs.normalize(p2.cwd), dir_persist_two, "restored PersistTwo cwd")
                ok(contains(p2.files, file_persist_b), "restored PersistTwo buffer")
                eq(vim.fs.normalize(p2.active), vim.fs.normalize(file_persist_b), "restored PersistTwo active buffer")
            end
            eq(result.tabs, #vim.api.nvim_list_tabpages(), "restored tab count matches the saved session")
        end
    end

    local tabs_before_reload = #vim.api.nvim_list_tabpages()
    vim.api.nvim_exec_autocmds("SessionLoadPre", {})
    vim.api.nvim_exec_autocmds("SessionLoadPost", {})
    wait_for(function()
        return #workspace.list() == tabs_before_reload
    end, "manual session restore rebuilt the registry")
    local workspaces_after_first = #workspace.list()
    vim.api.nvim_exec_autocmds("SessionLoadPost", {})
    wait_for(function()
        return #workspace.list() == workspaces_after_first
    end, "duplicate SessionLoadPost is idempotent")
    eq(workspaces_after_first, tabs_before_reload, "duplicate session load does not duplicate workspaces")
    ok(workspace.find("PersistOne") ~= nil, "manual session restore keeps named workspaces")
    ok(workspace.find("PersistTwo") ~= nil, "manual session restore keeps the second workspace")

    local health_ok, health_err = pcall(function()
        require("workspace.health").check()
    end)
    ok(health_ok, "health check runs: " .. tostring(health_err))
end)

vim.o.hidden = true
if not suite_ok then
    fail("test suite threw: " .. tostring(suite_err))
end

if #failures > 0 then
    io.stdout:write(string.format("%d test(s) failed\n", #failures))
    vim.cmd("cquit 1")
else
    io.stdout:write("all tests passed\n")
    vim.cmd("qa!")
end
