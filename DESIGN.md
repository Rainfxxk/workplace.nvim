# workspace.nvim 技术调研与实现方案

> 目标：以 Neovim tabpage 为边界，实现“工作区（workspace）”概念。每个工作区拥有独立的
> 工作目录、独立的缓冲列表、独立的窗口布局，以及可持久化的名称与状态。
>
> **实现状态（2026-10-21）**：Phase 1 与 Phase 2 已完成，代码见 `lua/workspace/`、
> `lua/telescope/_extensions/workspace.lua`、`README.md`、`tests/`。包含：
> 运行时核心、命令/API、tabline、关闭策略、session sidecar 持久化、
> Telescope 工作区切换器、health 与 headless 测试。
>
> 文中 Neovim 行为均在本机 **NVIM v0.12.1** 上做过 headless 验证。

---

## 0. 结论摘要

方案可行，而且 Neovim 已经提供了两个关键原生能力：

1. **工作目录**：`:tcd` 提供 tab 级 cwd，`getcwd(-1, tabnr)` / `haslocaldir(-1, tabnr)`
   可读取，`DirChanged` 的 `v:event.scope` 可监听。新 tab 会继承当前 tab 的本地目录。
2. **窗口布局**：tabpage 本身就会保留其中的窗口和布局，切换到其他 tab 不会销毁它们，
   因此不需要插件额外保存窗口布局。

需要插件补足的核心是“状态层”：

- **缓冲列表**：Neovim 的 buffer list 是全局的，没有 per-tab buffer list。推荐用
  `buflisted` 开关实现**逻辑隔离**：当前工作区的 buffer 设为 listed，其他工作区的
  buffer 设为 unlisted。bufferline、telescope buffers、`:ls`、`:bnext` 都基于
  `buflisted`，因此可以自然获得每个 tab 独立的 buffer 体验；只要 buffer 未被 Neovim
  unload（建议设置 `hidden=true`），undo 历史、LSP 连接和已加载内容都会保留。
- **显式状态**：每个 tab 的 `t:workspace_nvim` 记录 + Lua registry 索引，维护稳定
  workspace ID、name、cwd、buffer membership；不要像 scope.nvim 那样只依赖 TabLeave
  时的 listed buffer 快照，也不要用 tab handle 做持久化 key。
- **持久化**：session 文件能保存 tab 布局和 tab-local cwd，但**不保存 tabpage 变量**；
  且 `mksession` 不会保存所有隐藏的 unlisted buffer。需要插件旁的元数据快照
  （sidecar JSON）或 session 内的全局变量来保存名称、cwd、完整 buffer membership。
- **冲突处理**：本项目与 scope.nvim 的 `buflisted` 管理逻辑直接冲突，必须二选一；
  当前用户在 `~/.config/nvim` 中已启用 scope.nvim，迁移时应移除。

推荐的最小可行版本（MVP）范围：

- 所有 tab 自动注册为 workspace；
- tab-local cwd 的创建、继承、同步与 `:cd` 写回；
- buffer membership + `buflisted` 作用域；
- 工作区命名、tabline、命令与 Lua API；
- 基于 `SessionLoadPost` / `SessionWritePost` 的 session 元数据恢复；
- 测试、health check、与 bufferline/telescope/persistence.nvim 的集成说明。

**不推荐**通过 `bdelete`/`bwipeout` 或强制 `bunload` 来模拟“每个 tab 独立 buffer”，
那会丢失 undo、LSP attach 状态，也会误伤跨 tab 共享的 buffer。tab 之间是逻辑隔离，
不是进程级隔离。

---

## 1. 目标与非目标

### 1.1 目标

1. **Tab = Workspace**：每个 tab 是一个工作区，切换 tab 即切换工作区。
2. **CWD 独立**：每个工作区有自己的 tab-local 工作目录。
3. **Buffer 列表独立**：当前工作区的 buffer 列表与 UI 只显示本工作区 buffer；
   `:ls`、`:bnext`、bufferline、telescope buffers 等行为一致。
4. **窗口布局独立**：交给 Neovim 原生 tabpage，无需重造。
5. **可命名、可识别**：工作区有稳定名称、tabline 显示、命令/API 可操作。
6. **可持久化**：配合 session 管理器，重启后恢复 tab、名称、cwd、buffer 列表。
7. **对生态友好**：不修改全局键位，不依赖重型插件，bufferline/telescope/lualine
   可直接工作或通过轻量集成工作。

### 1.2 非目标（至少 MVP 不做）

- **不是进程隔离**：所有工作区仍在同一个 Neovim 进程内，共享全局寄存器、命令历史、
  undo 树（对同一 buffer）、mark、quickfix list、LSP client、DAP 会话、全局选项等。
- **不是 security/namespace 隔离**：unlisted 的 buffer 仍可被 `:buffer N`、插件 API
  访问；不能用作安全边界。
- **不隔离 quickfix**：quickfix list 是全局的；location list 与窗口相关但不是工作区级别。
- **不强制每个工作区一套 LSP 实例**：LSP 按 buffer/root 启动，跨工作区可共享。
- **不隔离外部进程的 cwd**：`uv.cwd()`、未显式传 `cwd` 的 job 等仍使用 Neovim 进程的
  全局 cwd；详见“已知限制”。
- **不在 v1 重造 session 管理器**：复用用户已有的 `:mksession` 类插件。

---

## 2. Neovim 机制调研

### 2.1 Tabpage、Window、Buffer 的基本关系

- Tabpage 是窗口容器。每个 tab 有自己的窗口树与布局。
- Buffer 是全局对象；同一个 buffer 可以同时显示在多个 tab 的窗口中。
- Neovim **没有** per-tab buffer list API。`tabpagebuflist()` 只返回某个 tab 的窗口中
  当前显示的 buffer，不是“该 tab 打开过的所有 buffer”。

因此“每个 tab 的 buffer 相互独立”只能通过以下之一实现：

| 方案 | 机制 | 优点 | 缺点 |
|---|---|---|---|
| A. 逻辑作用域（推荐） | 维护 buffer↔workspace membership，切换时切换 `buflisted` | 保留 undo/LSP/内容；bufferline、telescope、`:ls`/`:bnext` 自动一致 | 需要处理 BufAdd/BufDelete 事件风暴；并非真正隔离 |
| B. UI 过滤 | 只用 bufferline 的 `custom_filter` 过滤显示 | 侵入性最小 | `:ls`、`:bnext`、telescope 等仍然是全局的 |
| C. 卸载/删除 | 离开 tab 时 `bunload`/`bwipeout` | 节省内存、观感更“隔离” | 丢 undo/文件状态/LSP；跨 tab 共享 buffer 会被误伤 |
| D. 多 Neovim 实例 | 每个项目一个进程 | 真正隔离 | 不是 tab 方案；资源开销大 |

**本项目选择 A**，并保留 B 作为可选的保守模式（如果后续发现生态兼容性成本过高）。

### 2.2 工作目录：`:tcd` 与 `DirChanged`（已实测）

Neovim 有四级 cwd，优先级从高到低：

1. buffer（`:bcd`）
2. window（`:lcd`）
3. tabpage（`:tcd`）
4. global（`:cd`）

关键 API / 命令：

- `:tcd {path}`：仅设置当前 tab 的 cwd；会清除当前 window 的本地目录，但
  **buffer-local `:bcd` 仍然优先**。
- `:tcd!`：取消当前 tab 的本地目录。
- `:lcd {path}`：仅设置当前 window 的 cwd。
- `:bcd {path}`：设置当前 buffer 的 cwd；因为 buffer 可跨 tab 共享，它可能覆盖
  多个工作区的 tab-local cwd，工作区方案默认不支持/不归一化。
- `getcwd([winnr, tabnr])`：
  - 无参数：当前有效 cwd；
  - `getcwd(-1, tabnr)`：只解析 tab（返回 tab 级或更外层目录）；
  - `getcwd(-1, -1)`：global cwd；
  - `tabnr` 使用 tab 的**编号**（会随 tab move/close 变化），不是 tab handle。
- `haslocaldir(-1, tabnr)`：tab 是否通过 `:tcd` 设置过本地目录。
- `DirChanged` / `DirChangedPre` 的 `v:event`：
  - `scope`：`"global"` / `"tabpage"` / `"window"` / `"buffer"` / `"auto"`
  - `DirChanged` 的 `cwd` / `DirChangedPre` 的 `directory`：新目录
  - `changed_window`：因切换窗口/tab 触发的有效 cwd 变化（不是用户主动改目录）

**实测结论（v0.12.1）**：

- `:tabnew` 会把当前 tab 的 tab-local cwd 继承给新 tab（`haslocaldir=1`）。
- 在 tab 2 中执行 global `:cd /` 会清除 **当前 tab** 的 tab-local cwd，但不影响其他 tab。
- 可以通过 `nvim_win_call(tab 的任意 window, function() vim.cmd.tcd(path) end)`
  在**不切换当前 tab** 的情况下，给另一个 tab 设置 cwd；实测只触发了
  `DirChanged`，没有触发 WinEnter/TabEnter，焦点也会恢复。
- 切换 tab 且目标 tab 的有效 cwd 不同时，事件顺序实测为
  `TabLeave → DirChangedPre/DirChanged → TabEnter`，且带有 `changed_window=true`；
  处理 cwd 时应忽略这种“因切换导致的事件”。
- 新 tab 通过 `:tabnew` 创建时，cwd 的继承发生在 TabNew 之前；
  **如果要求“新工作区总是使用固定目录”，必须在创建后显式 `:tcd`。**

**设计含义**：

- 用 `:tcd` 作为每个 workspace 的 cwd 载体，插件记录一份 `ws.cwd` 作为权威状态。
- 用 `DirChanged` 同步用户手动执行的 `:tcd` / `:cd`；不要把 `DirChanged` 当作
  唯一的状态转换钩子，tab 生命周期仍以 `TabNew`/`TabEnter`/`TabClosed` 为准。
- 对当前 tab 之外的 workspace 设置 cwd 时，使用 `nvim_win_call`，并设置 guard 避免
  自己的 DirChanged 递归。
- 对 `lcd` / `bcd` 保持克制：workspace 只管理 tab 级 cwd；window/buffer 级差异允许
  存在，但 effective cwd 可能不等于 workspace cwd，需在文档/health 中提示。
  `bcd` 尤其危险，因为它会跟随共享 buffer 影响多个工作区。

#### `:cd` 的写回语义（需要明确的产品决策）

`:cd` 在某个工作区内执行时，会清掉当前 tab 的 tcd。如果插件什么都不做，用户会觉得
“cd 没生效”。推荐：

1. 监听 `DirChanged`，`scope == "global"` 且 `changed_window == false`；
2. 把新目录写入当前 workspace 的 `cwd`；
3. 立刻用 `:tcd` 重新锁定当前 tab 的本地目录（设置 guard）；
4. 触发 `WorkspaceChanged` 事件。

这样 `:cd` 在当前工作区内表现为“修改当前工作区目录”，不会影响其他工作区。需在文档中
写明这一非标准语义。

### 2.3 Buffer 作用域：`buflisted` 是否可靠（已实测）

结论：**可靠，且生态兼容性最好**。

实测：

- 将 buffer 的 `buflisted` 设为 `false`：
  - buffer 仍然是 valid/loaded（`bufloaded=1`，只要未被 Neovim 自动 unload）；
  - 触发 `BufDelete` autocmd；
  - 从 `:ls`、`:bnext` 中消失；
  - 在 buffer 保持 loaded 期间，undo history、LSP attach 等不受影响。
- 将 `buflisted` 设为 `true`：触发 `BufAdd`。

**因此建议用户设置 `hidden=true`**：否则隐藏 buffer 可能被自动 unload，虽然 membership
仍然保留、之后可重新加载，但 undo 历史会丢失。`hidden` 不是本插件的强制项，而是
使用体验/状态保留的重要前提（health 中给出建议）。
- bufferline.nvim 的 buffer 收集逻辑（本机源码）明确只取 `listed == 1` 的 buffer；
  telescope 的 buffers picker 也过滤 `buflisted`。
- 因此只要切换 tab 时更新 listed 集合，**bufferline/telescope/`:ls`/`:bnext` 会自动
  呈现 per-workspace 的 buffer 列表**，无需分别 patch 每个插件。

需要注意的副作用：

1. **`BufDelete` 事件风暴**：插件自己的 listed 切换会触发 `BufDelete`。如果用
   `BufDelete` 来清理 membership，会把自己的作用域切换误认为用户删除 buffer。
   必须用 `scope_sync` guard，且成员清理主要依据 `BufWipeout` / 用户显式操作。
2. **session 管理器过滤**：resession 等插件的默认 `buf_filter` 可能跳过 nobuflisted
   buffer；scope.nvim 也专门要求自定义 filter。我们的 sidecar 方案不以 session
   过滤为准，避免依赖这些插件的默认行为。
3. **外部插件改变 `buflisted`**：例如某些 picker/文件树可能自行 unlist buffer。
   如果不在 guard 内，可能被误判为用户删除。设计上只清理“明确不再属于任何 workspace”
   的 buffer，或提供禁用 `buflisted` 管理的 UI-only 模式。
4. **关闭 tab 时不会触发 `BufDelete`**（实测触发 `BufUnload` 或什么都不触发），
   membership 清理必须由 tab 关闭事件自己完成。
5. **卸载与 listed 无关**：默认 `hidden=false` 时，隐藏未修改 buffer 会被 unload；
   membership 仍保留（bufnr 依然 valid）。建议用户开启 `hidden=true` 以便 tab 内
   隐藏 buffer 更稳定地保留 undo；插件不强制修改该选项。
6. **modified buffer 的安全**：`buflisted` 不影响 `:qa`/`:wall` 对 modified buffer
   的检查；但关闭 tab 时 Neovim 自己的行为不变，仍有未保存提示。插件不要在
   autocmd 中弹交互框，需 `vim.schedule`。

### 2.4 Buffer membership 的定义

推荐：**一个 buffer 在某个工作区的窗口中显示过，就加入该工作区；直到用户显式删除
（bdelete/wipeout）或工作区关闭，才移除。** 这样与 bufferline 的“打开过就留在列表里”
一致，不会因为窗口关闭而丢失 buffer 列表。

- 同一 buffer 可以被多个 workspace 共享（例如在 A 中打开，后在 B 中也打开）。
  membership 是多对多集合；undo、内容、LSP 自然是共享的。
- 当前工作区窗口里显示的 buffer 必须在同步 listed 前加入 membership，否则会在
  进入新 tab 的瞬间把它 unlist。
- 共享 buffer 的关闭（bufferline 的 close）是全局行为；如需要“只从当前工作区移除”，
  后续可以提供 `workspace.detach_buffer()` / `:WorkspaceDetachBuffer`。

### 2.5 Session 持久化调研（已实测，重要）

#### `:mksession` 能保存什么

- 默认 `sessionoptions`（含 `tabpages`）：保存所有 tab 及窗口布局。
- **含 `curdir` 时**：保存 global cwd，并在每个 tab 写入 `tcd`；恢复后 tab-local
  cwd 正确恢复。**不含 `curdir` 时，`tcd` 不会写入 session**。
  实测：`sessionoptions=buffers,tabpages,globals` 保存后，两个 tab 的 tcd 全部丢失，
  恢复后都回到 global cwd。
- **tabpage 变量（t:）、window 变量、buffer 变量不保存**。实测 session 文件中没有
  任何 `settabvar`/`setwinvar`/`setbufvar` 记录。
- **只保存 session 中窗口所涉及的 buffer，以及部分 loaded buffer；不会保存所有隐藏且
  unlisted 的 buffer。** 实测：一个属于非当前 tab、无窗口、unlisted、已 unload 的
  buffer，在 session 中完全消失。因此如果要恢复“每个工作区的完整 buffer 列表”，
  必须由插件额外记录 buffer 路径。
- `sessionoptions=buffers` 的语义是“隐藏和 unload 的 buffer”，但在“无窗口 + unlisted”
  场景下实测仍不可靠；不要依赖它做完整 membership 恢复。

#### session 相关事件

- `SessionWritePost`：`:mksession` 写完后触发；此时 `vim.v.this_session` 是 session
  文件路径。可以在这里写 sidecar。
- `SessionLoadPre` / `SessionLoadPost`：加载 session 前后触发；`v:this_session` 可用。
  `SessionLoadPre` 是 0.12 新增；0.11 及以下只有 `SessionLoadPost`（历史事件）。
  `SessionLoadPost` 在 `:source session.vim` 时触发，可用于恢复插件状态。
- 注意 `:source` 一个 session 可能会触发两次 `SessionLoadPost`（实测），恢复逻辑必须幂等。

#### 持久化方案选项

| 方案 | 优点 | 缺点 |
|---|---|---|
| A. session 文件旁的 sidecar JSON（推荐主方案） | 不受 sessionoptions `globals` 限制；完整保存名称/cwd/buffer membership；实现清晰 | session 文件被移动/复制时 sidecar 会脱节 |
| B. 写入 `vim.g.WorkspaceNvimState`，借 sessionoptions `globals` 随 session 保存 | 单文件、跟随 session 移动；scope.nvim 采用类似方案 | 强制要求 `globals`；全局变量在 session 之间可能残留；仍不适合很大状态 |
| C. 插件自己的 state.json + 固定恢复顺序 | 不依赖 session 管理器 | 无法知道用户加载的是哪个历史 session，容易错配 |
| D. 每次 source 后重算 visible buffer | 无额外状态 | 丢失隐藏 buffer、名称、用户命名等信息 |

**推荐**：主方案 A（sidecar）+ 可选的 B 兼容层，并在 API 中暴露手动
`serialize/load` 供 session 管理器集成。

sidecar 建议路径：`v:this_session .. ".workspace.json"`，使用原子写（临时文件 + rename）。

### 2.6 现有实现与可借鉴点

本机已安装 scope.nvim，另有若干相关项目值得对照（按 2026-10 时的源码/README）：

| 项目 | 机制 | 可借鉴 / 不可取 |
|---|---|---|
| [scope.nvim](https://github.com/tiagovla/scope.nvim) | `TabLeave` 时把当前 listed buffer 缓存到 `cache[tab_handle]`，全部 unlist；`TabEnter` 重新 list；session 以 `vim.g.ScopeState` 保存，需要 `globals` | 借鉴以 listed 作为 UI 投影；**不要**借鉴从 listed 反推 membership、用 tab handle 做持久化 key |
| [tabscope.nvim](https://github.com/backdround/tabscope.nvim) | 同样是 `buflisted` 切换；对 tab 关闭有更多清理 | README 明确警告：session 加载后无法恢复隐藏 buffer；印证 sidecar 必要性 |
| [tabLocalBuffer.nvim](https://github.com/akasataikisiti/tabLocalBuffer.nvim) | 用 tabpage 变量保存显式 buffer 列表；`BufWinEnter` 加入、`TabEnter` 与窗口同步、`BufWipeout` 清理；提供 move/detach/delete 命令 | 与本项目的 membership 模型最接近；缺少 cwd 与 session 持久化 |
| [vim-tabws](https://github.com/s1341/vim-tabws) | 老式 Vimscript 工作区：自动项目根、`:tcd`、项目 buffer 列表、覆盖 `:ls`/`:buffer`、tag stack | 可借鉴项目根自动路由、workspace picker、tag stack；不要覆盖原生命令 |
| [bufferline.nvim](https://github.com/akinsho/bufferline.nvim) | 全局 bufferline，只读 listed buffer；`custom_filter` 是纯显示过滤；用 tabpage 变量 `name` 作为 tab 名约定 | 与 `buflisted` 投影天然协作；同时设置 `t:name` 兼容它的 tabs 模式 |
| [barbar.nvim](https://github.com/romgrk/barbar.nvim) | 全局 bufferline，有自己的全局 buffer order | 与 scope 存在顺序冲突（#556）；不要把它的内部顺序纳入设计 |
| [tabby.nvim](https://github.com/nanozuki/tabby.nvim) | tabline/UI 框架，不是 buffer 作用域；tab 名称存 `g:TabbyTabNames`（按 tab 序号） | 借鉴“SessionLoadPost 后按序号恢复名称”；序号需要重新校验 |
| [workspaces.nvim](https://github.com/natecraddock/workspaces.nvim) | 目录注册表 + picker；`cd_type="tab"` 用 `:tcd` | 可选作为工作区目录/picker 前端；不提供 buffer 列表或布局 |
| [nvim-contabs](https://github.com/m00qek/nvim-contabs) | 仅管理 tab cwd，并用 cwd 过滤 fzf buffer | 说明 cwd 与 buffer picker 的联动需求；不含持久化 membership |

scope.nvim 的已知问题尤其能说明设计取舍：

- session 状态用 tab handle 作为 key，序列化后变成 1..n 索引；tab 关闭/重排后 handle
  不连续，恢复会错位或丢失（[#43](https://github.com/tiagovla/scope.nvim/issues/43)）。
- 隐藏且 unlisted 的 buffer 不会被 `mksession` 保存，需要事后 `badd`
  （[#28](https://github.com/tiagovla/scope.nvim/issues/28) + PR #30）。
- 在另一个 tab 里 `:buffer N`、`:tab sb`、`<C-w>T` 等操作会让 scope 状态与实际
  tab 归属不一致（[#14](https://github.com/tiagovla/scope.nvim/issues/14)、
  [#2](https://github.com/tiagovla/scope.nvim/issues/2)、
  [#25](https://github.com/tiagovla/scope.nvim/issues/25)）。
- cwd 功能 PR #9 未合并；名称请求 #3/#24 未实现。
- 使用已废弃的 `nvim_buf_set_option`（0.11+ 建议 `vim.bo`）。

**结论**：借鉴其 `buflisted` 投影与事件挂载位置，但本项目采用**显式 membership +
tabpage 局部记录 + 稳定 workspace ID + sidecar**，并从 tabLocalBuffer.nvim 借鉴
显式生命周期。

### 2.7 版本与事件可用性

本机：NVIM 0.12.1，LuaJIT。事件可用性（依据 0.10/0.11/0.12 发布文档）：

| 事件 | 0.10 | 0.11 | 0.12.1 | 说明 |
|---|---|---|---|---|
| `TabNew` | 是 | 是 | 是 | WinEnter 后、TabEnter 前；没有 `TabNewPre` |
| `TabNewEntered` | 是 | 是 | 是 | BufEnter 后，适合 UI 刷新 |
| `TabClosed` | 是 | 是 | 是 | `<afile>` 是关闭前的 tab 编号 |
| `TabClosedPre` | 否 | 否 | 是 | 关闭前，当前 tab 即待关闭 tab；layout 锁定 |
| `SessionLoadPre` | 否 | 否 | 是 | 0.12 新增 |
| `SessionLoadPost` | 是 | 是 | 是 | 恢复后 |
| `DirChanged` / `DirChangedPre` | 是 | 是 | 是 | scope 与事件数据语义见 2.2 |

**已确认 v1 最低版本为 0.12+**：直接使用 `TabClosedPre`、`SessionLoadPre`、
`nvim_open_tabpage`，不实现 0.10/0.11 fallback。CI 使用 0.12.x + nightly；
以后若需要扩大兼容面，再单独设计旧版路径。



---

## 3. 总体架构

```text
                  ┌──────────────────────────────┐
                  │        Neovim tabs           │
                  │  tab1          tab2      ... │
                  └──────┬───────────┬───────────┘
                         │           │
              tabpage var│           │tabpage var
                         ▼           ▼
                  ┌──────────────────────────────┐
                  │   Workspace registry (Lua)   │
                  │  ws.id, name, cwd, bufs set  │
                  │  tab ↔ ws, buf ↔ ws sets     │
                  └──────┬───────────┬───────────┘
                         │           │
            ┌────────────▼───┐  ┌────▼────────────────┐
            │  CWD manager   │  │  Buffer scope       │
            │ :tcd, DirChanged│  │ membership+listed   │
            └────────────────┘  └─────────────────────┘
                         │           │
                  ┌──────▼───────────▼───────┐
                  │   UI / API / commands    │
                  │ tabline, picker, events  │
                  └──────────────┬───────────┘
                                 │
                  ┌──────────────▼───────────┐
                  │ Session integration      │
                  │ sidecar / global var     │
                  └──────────────────────────┘
```

### 3.1 状态模型（概念结构）

```text
Workspace = {
  id: string,                -- 稳定 workspace ID（创建时生成并持久化）
  tab: tabpage handle,       -- 存活期间有效；不持久化
  name: string,              -- 显示名
  name_custom: boolean,      -- 用户是否手动命名（决定 cwd 变化时是否自动改名）
  cwd: string,               -- 规范化绝对路径；权威值
  buffers: list<bufnr>,      -- 运行时成员（有序、去重）；持久化时转成路径
  -- 当前 buffer、窗口布局由 tab/window 原生状态提供，不重复存储
}

-- 推荐把每个 tab 的 Workspace 记录写入 tabpage 变量：
--   t:workspace_nvim = { id, name, name_custom, cwd, buffers = {...} }
--   t:name = name   -- bufferline 的 tab 名约定
-- session 不会保存 t:，因此持久化仍走 sidecar。

Registry（进程内索引/缓存，可由 t: 记录重建） = {
  workspaces: map<id, Workspace>,
  by_tab: map<tabpage, id>,
  memberships: map<bufnr, set<id>>,  -- 反向索引，便于清理/共享
  active_id: id?,
  updating_scope: boolean,           -- guard：BufAdd/BufDelete 事件
  updating_cwd: boolean,             -- guard：DirChanged
  hydrating: boolean,                -- session/批量恢复中，抑制事件与写盘
}
```

设计原则：

- **tabpage 是运行时的锚点**；tab 关闭即 workspace 结束，t: 记录随之自动释放。
- **tab handle 是不透明且可能不连续的整数**（关闭/重排后可能出现 4、5、6），
  不能假定连续，也绝不持久化；持久化使用稳定 ID + tab 顺序/anchor。
- 推荐让 **tabpage 局部记录作为 per-tab 权威数据**，Lua registry 只是索引/缓存：
  tab 关闭时不会留下全局 stale cache，插件 reload 也能从 t: 恢复名称/cwd。
- tabpage 变量 session 不保存，恢复后重新赋值；名称/cwd/membership 的持久化以
  sidecar 为准。
- workspace 的当前 buffer、窗口布局不复制；需要时从 tab 读取。
- buffer membership 是显式状态，不从 listed 状态反推。
- 设置 `t:name` 作为 bufferline tabs 模式的兼容约定；自定义 tabline 优先读取
  `t:workspace_nvim.name`。

### 3.2 建议的模块结构

```text
lua/workspace/
  init.lua            -- setup、公共 API 聚合
  config.lua          -- 配置默认值、校验
  registry.lua        -- 状态索引/缓存（t:workspace_nvim 为权威）、tab↔ws、buffer↔ws、ID/guard
  lifecycle.lua       -- tab/buffer/cwd 事件处理与 reconcile
  cwd.lua             -- tcd 读写、DirChanged 语义、win_call
  scope.lua           -- 可见 buffer 收集、eligible 判定、listed 同步
  close.lua           -- 工作区关闭策略与清理
  api.lua             -- 高层操作
  commands.lua        -- 用户命令与补全
  tabline.lua         -- 可选 workspace tabline renderer
  session.lua         -- sidecar 序列化/恢复与 session 事件
  health.lua          -- :checkhealth workspace
  util.lua            -- 路径、tab、buffer、notify 等工具
lua/telescope/_extensions/workspace.lua -- Telescope 工作区切换器
README.md              -- 使用文档
tests/                 -- headless 集成测试（含 session 子进程与 Telescope 测试）
```

职责边界：

- `registry` 维护状态索引/缓存，不直接操作 Neovim；per-tab 权威记录在
  `t:workspace_nvim`；
- `lifecycle` 负责事件编排，调用 cwd/scope；
- `cwd` / `scope` 都是“对权威状态的投影”，必须用 guard；
- `session` 只读写快照，不参与运行时同步；
- UI 与集成层只消费公共 API，不直接修改 registry。

---

## 4. 核心机制设计

### 4.1 生命周期与事件矩阵

| 事件 | 时机/说明 | 处理 |
|---|---|---|
| 插件加载 / VimEnter | 可能已有多个 tab（尤其 `-S session`） | 采纳现有所有 tab；为每个 tab 建立/恢复 `t:workspace_nvim`、稳定 id、名称、锁定 cwd；收集可见 buffer |
| `TabNew` | 新 tab 已存在，尚未 TabEnter；没有 `TabNewPre`，这是最早的创建钩子 | 创建 Workspace；根据配置决定继承/指定 cwd；写 tabpage var 和 `t:name` |
| `TabEnter` | 进入 tab（新 tab 上先于 BufEnter；切换时可能有 DirChanged 发生在此之前） | 确保 workspace；收集本 tab 非浮动窗口中的可见 buffer；同步 listed buffer；更新 active |
| `TabNewEntered` | 新 tab BufEnter 后 | 兜底加入当前 buffer、同步 listed；主要用于 UI 刷新 |
| `TabLeave` | 离开 tab | 不做列表变更（由目标 tab 的 TabEnter 统一同步，避免中间态）；记录 last active 以兼容 0.12 以下的关闭清理 |
| `TabClosedPre`（0.12） | 关闭前，布局锁定；对非当前 tab 也会把“关闭中的 tab”作为 current | 记录即将关闭的 tab/id 和 t: 记录；不做窗口或 cwd 操作 |
| `TabClosed` | 关闭后；`args.file` 是关闭前的 tab 编号 | 清理 workspace；把只属于它的 buffer unlist 并移出管理；处理孤儿 buffer；触发事件 |
| `BufWinEnter` / `BufEnter` | buffer 在窗口显示/进入 | `BufWinEnter` 是 membership 的主要来源；若属于可管理 buffer，加入当前 workspace；确保 listed |
| `BufAdd` | buffer 加入 buffer list | 默认不处理（避免与自己的 list 操作和后台 buffer 冲突）；由 BufWinEnter 兜底 |
| `BufDelete` | buffer 从列表删除；**也可能是自己 unlist 导致** | 若 `updating_scope` 为真则忽略；否则移除所有 membership |
| `BufUnload` | buffer 被卸载 | 不删除 membership（tab 关闭/隐藏会触发） |
| `BufWipeout` | buffer 被彻底删除 | 移除所有 membership |
| `DirChanged` / `DirChangedPre` | cwd 变化；scope 可为 global/tabpage/window/buffer/auto | 忽略 `changed_window=true` 和 guard 内事件；按 scope 同步 workspace cwd；buffer/window scope 不修改 ws.cwd |
| `SessionWritePost` | `:mksession` 完成 | 写 sidecar 快照（或同步全局状态） |
| `SessionLoadPost` | session source 完成 | 重建 registry，恢复名称/cwd/membership/listed；幂等 |
| `VimLeavePre` | 退出前 | 可选写状态快照（无 session 管理器时）；清理挂起任务 |

事件注册建议：

- 统一 augroup，`setup()` 幂等，不重复注册。
- 每个 handler 用 `pcall` 包裹，不能因单个失效 buffer 中断整个切换。
- 所有可能会弹 UI 的操作（确认框、input）都 `vim.schedule`，避免在 autocmd/textlock
  中执行。
- v1 只支持 0.12+，因此可以直接依赖 `TabClosedPre`；不需要维护旧版本 fallback。
  仍不要假定 tab handle 连续，也不要用 tab handle 持久化。
- 保存/恢复 session 时建议临时抑制插件 autocmd（或使用 `hydrating` guard），
  避免 session 重建 tab 时触发状态写入。

### 4.2 CWD 管理器

#### 创建/采纳

1. 采纳现有 tab：
   - 如果已有 `t:workspace_nvim` 记录（插件 reload/重复 setup），优先使用其中的
     id/name/cwd，不要重复建 workspace；
   - 当前 tab 用 `getcwd()`，其他 tab 用 `getcwd(-1, tabnr)`；如果该 tab 没有 tcd，
     则用 global cwd 作为 workspace cwd；
   - **无论如何都显式 `:tcd` 绝对路径锁定该 tab**，避免随后 global `:cd` 或无本地
     目录的 session 恢复影响它；
   - 设置 tabpage var、`t:name`，加入 registry。
2. 新建工作区：
   - 默认 `new_tab_cwd = "inherit"`：记录当前有效 cwd，并显式 `:tcd`，不依赖
     `:tabnew` 的继承；
   - `"global"`：使用 `getcwd(-1, -1)`；
   - 命令显式传目录：规范化后 `:tcd`；
   - 名称默认取 cwd 的 basename；冲突时追加序号。
3. 名称策略：
   - 未手动命名时，cwd 变化后自动更新为 basename；
   - 用户 rename 后 `name_custom = true`，不再自动改名；
   - 允许重名（tabline 显示序号），命令按名称匹配多个时用 `vim.ui.select` 或报错。

#### 切换/同步

- **每个工作区创建/恢复时都显式执行 `:tcd`**，不依赖 `:tabnew` 的继承行为；这能避免
  无本地目录的 tab 在恢复时意外沿用上一个 tab 或 global cwd。
- 进入 tab 时，如果当前 workspace 的 canonical cwd 与 tab 的 tcd 不一致（插件自身或
  外部原因导致），以 workspace 为准重新 `:tcd`；如果目录不存在，通知并回退到最近
  有效祖先或 home（可配置），不要让整个 tab 切换失败。
- 对非当前 tab 应用 cwd：`nvim_win_call` + guard；失败时记录错误并通知。
- 始终使用绝对路径存储；展示用 `fnamemodify(path, ":~")`。
- 不在进入 tab 时静默清除 window-local cwd（`:lcd`）或 buffer-local cwd（`:bcd`）；
  workspace cwd 是 tab 级，effective cwd 可能与之不同，这属于 Neovim 原生语义。
  文档需要明确：`lcd`/`bcd` 会让 `getcwd()` 偏离 workspace cwd；`bcd` 会跟随共享
  buffer 影响多个工作区，默认不支持、health 可提示。
- `:tcd!` 会取消 tab-local 目录；若用户在 workspace 中执行，应视为“回到 global
  有效目录”，更新 `ws.cwd` 并重新锁定，避免工作区处于无本地目录的不稳定状态。

#### DirChanged 处理

```text
if vim.v.event.changed_window or registry.updating_cwd then return end
local ws = current()
if not ws then return end
if scope == "tabpage" then
  ws.cwd = normalize(event.cwd)
elseif scope == "global" then
  ws.cwd = normalize(event.cwd)
  set_tcd_for_current_tab(ws.cwd)   -- 重新锁定；设置 guard
elseif scope == "window" or scope == "buffer" then
  -- 不修改 ws.cwd；window/buffer-local cwd 是原生特性
  -- 按需触发 hook 或 health 提示（bcd 尤其危险）
elseif scope == "auto" then
  -- autochdir 模式：health 警告；不要静默覆盖 workspace cwd
end
fire Changed
```

注意：

- `:cd` 会先清除当前 tab 的 tcd，再触发 global scope 事件；我们在事件后重新
  `:tcd`，所以 guard 必须覆盖“重设 tcd”导致的 tabpage 事件。
- tab 切换时 `DirChanged` 可能发生在 `TabLeave` 之后、`TabEnter` 之前，且带
  `changed_window=true`；必须忽略，工作区状态转换不要依赖它。
- 不要把 `DirChanged` 当作唯一入口；`TabEnter`/`TabNew` 仍需显式校验并设置 tcd。

### 4.3 Buffer 作用域管理器

#### 4.3.1 哪些 buffer 纳入管理

默认纳入：

- 普通文件 buffer（`buftype == ""`）；
- terminal buffer（需要与工作区一起管理；但 session 恢复可能受限）；
- help buffer（默认也可纳入，避免出现在所有工作区）；
- 其他“在非浮动窗口中显示”的 buffer（按配置可排除）。

默认排除：

- `buftype` 为 `nofile`、`prompt`、`quickfix` 等临时 buffer；
- 只显示在浮动窗口中的 picker/preview buffer；
- 可配置的 filetype 排除列表。

实现要点：

- 判断“显示在非浮动窗口”：遍历 `nvim_tabpage_list_wins(tab)`，过滤
  `nvim_win_get_config(win).relative ~= ""` 与特殊 buftype。
- 不要用 `tabpagebuflist()` 直接作为可见集合，因为它包含浮窗。
- `BufWinEnter` 时同样检查该 buffer 是否在非浮动窗口中出现；只有这样才加入。

#### 4.3.2 激活工作区时的同步算法

```text
function sync_scope(ws):
  guard(updating_scope)
  -- 1. 收集当前 tab 非浮窗中的 buffer，先加入 membership
  for b in visible_buffers(ws.tab):
    if eligible(b) then attach(ws, b)
  -- 2. 列出本工作区全部成员
  for b in ws.buffers:
    if valid(b) and eligible(b) and not listed(b):
      set buflisted = true
  -- 3. 隐藏其他工作区成员（只操作“被管理”的 buffer）
  for b in managed_buffers() - ws.buffers:
    if listed(b): set buflisted = false
  unguard()
  fire WorkspaceEntered / Changed
```

关键点：

- **先收集再切换**，避免新 tab 当前 buffer 被临时 unlist。
- **只处理被管理的 buffer**：外部插件创建的全局 listed buffer（没有被任何 workspace
  采纳）不要随意 unlist；否则会与外部插件打架。可提供一个“orphan/global buffers”
  的清理策略，而不是全场 unlist。
- 自己设置 `buflisted` 时触发 BufDelete；`BufDelete` handler 检查 guard。
- 用户显式 `:bdelete`（guard 为 false）时，从所有 workspace 移除该 buffer；如果
  buffer 仍被其他 tab 的窗口显示，Neovim 原生的 bdelete 语义仍然生效（这是全局操作），
  文档要说明。
- `BufUnload` 不删除 membership（tab 关闭、隐藏行为会触发）。
- `BufWipeout` 统一清除。
- 每次 attach/detach 同时更新 Lua registry 与对应的 `t:workspace_nvim` 记录
  （如果选择把 buffer 列表放在 t: 中）；两者不一致时以 t: 记录为准并在下次
  reconcile 修复。

**原生“把 buffer 带到另一个 tab”的行为**：

- `:tab sb`、`:tab split`、`<C-w>T`、以及在另一个 tab 执行 `:buffer N` 都会让
  buffer 出现在新 tab 的窗口中。`TabNew`/`TabEnter` + `BufWinEnter` 会把它加入
  **新**的 workspace；它仍留在原 workspace。这种“共享”是合理且可预期的，文档中
  说明即可，不要试图阻止或自动移出。tabLocalBuffer.nvim 的显式 membership 也采用
  相同思路；scope.nvim 的 #2/#14/#25 正是缺少这一层归属导致的。
- 如果用户希望“移动”而不是“共享”，提供显式命令（如 future
  `:WorkspaceMoveBuffer` / `DetachBuffer`），不要猜测意图。

#### 4.3.3 工作区关闭（已确认策略）

关闭策略只适用于**用户主动关闭工作区**；session 恢复、退出 Neovim、切换 session
时不能删除 buffer。

1. 计算 `exclusive = ws.buffers - buffers(still referenced by other workspaces)`；
   `modified_exclusive` 为其中 modified 的 buffer。
2. **共享 buffer 永远不删除**；只从 closed ws 的 membership 移除。
3. **独占且未修改**：直接删除（关闭后调度，执行前再次检查 modified）。
4. **独占且 modified**：
   - `:WorkspaceClose`（插件命令）先通过 `vim.ui.select` 弹三选项：
     - 取消关闭；
     - 放弃修改并关闭（关闭后强制删除这些独占 buffer）；
     - 保留 buffer 并关闭（关闭后保留为隐藏/临时孤儿，不删除）。
   - 原生 `:tabclose` / 鼠标关闭 / 其他插件关闭：`TabClosedPre` **不能取消关闭**，
     因此不删除 modified 的独占 buffer；关闭后在可用时 notify 用户它们已被保留。
     未修改的独占 buffer 仍按策略清理。
5. 清理在 `TabClosed` 之后用 `vim.schedule` 执行，避免 layout lock；执行前重新检查
   buffer 是否仍 valid、是否仍无窗口、是否仍然未修改。任何异常都保留 buffer 并 notify，
   不能为了策略牺牲数据。
6. 选择“保留 buffer 并关闭”时，modified 的独占 buffer 变为 **孤儿 buffer**：
   从 membership 移除、unlist、保留 loaded；可通过 `:ls!` / 未来的 orphan picker
   找回。
7. 如果关闭的是当前 tab，Neovim 会先切换到另一个 tab；目标工作区的同步正常执行。
   关闭前的 `TabClosedPre` 用于捕获 workspace id 和独占 buffer 快照（0.12）。
8. 退出/加载 session 路径必须设置 `hydrating` / `quitting` guard，禁止上述删除。
9. 删除实现优先彻底 wipe（`bwipeout` 语义）；对 modified 的强制删除只在用户
   明确选择“放弃修改并关闭”后执行。

另外，`:tabnew` 会自动产生一个 unnamed 空 buffer；可在离开/关闭工作区时清理
“空、未修改、自动创建且无其他工作区引用”的 buffer，避免它们逐渐积累。该清理必须
可配置，且不能误删用户主动创建的空 scratch buffer（可用 buffer 变量标记来源）。

#### 4.3.4 性能

- 每次 tab 切换的复杂度是 O(当前/其他 workspace 的 buffer 数)；数十到数百 buffer
  可接受。切换时会产生 BufAdd/BufDelete 事件，bufferline 会重绘；避免在 TabEnter
  中做磁盘 I/O、shell 调用。
- 维护 `managed_buffers` 集合，避免全 buffer 扫描。
- 只有 membership 变化时才写 session sidecar（或在 SessionWritePost 时统一写）。
- 不要在 BufEnter 中执行同步扫描；只在需要加入 membership 时 O(1) 操作。
- 后续可加 benchmark（500/2000 buffer）并决定是否需要批量抑制事件。

### 4.4 命名与 tabline

- Neovim 没有原生“tab 名称”API（`guitablabel` 仅 GUI，TUI 不可用）。工作区名称必须
  通过自定义 `'tabline'` 或状态栏/其他 UI 展示。
- **同时写入 `t:name`**：bufferline.nvim 的 tabs 模式约定读取 tabpage 变量 `name`
  作为标签；写入它可以获得现成的兼容性。`t:name` 不会持久化，sidecar 恢复后再写。
- 推荐内置一个可选 tabline renderer：
  - 每个 tab 显示 `序号: 名称`，active 高亮；
  - 显示 modified 标记（该 tab 任一 buffer 修改）；
  - 可显示窗口数量；
  - 使用 `%{nr}T` 使标签可点击；
  - 名称中的 `%` 需要转义；
  - 通过 `options.tabline.enabled = "auto"` 决定：如果用户已设置非默认 `'tabline'`
    则不覆盖；也可显式开关。
- 不使用 `guitablabel`；TUI 下无效。
- 额外提供 lualine 组件所需数据（`name`, `cwd`, `buf_count`），不强制依赖。
- bufferline 无需改动：它的 `mode = "buffers"` 会自动只显示当前 listed buffer。
  如果用户用 bufferline 的 tabs 模式，则 tabline 可关闭；否则可复用它的 `t:name`。
- 名称的持久化不要照搬 tabby.nvim 的“按 tab 序号存 `g:TabbyTabNames`”作为唯一方案：
  序号是位置相关的；以 sidecar 中的稳定 ID + 顺序/anchor 为准。

### 4.5 Session 持久化设计

#### 4.5.1 快照内容

```json
{
  "version": 1,
  "saved_at": 1234567890,
  "session": "/path/to/session.vim",
  "workspaces": [
    {
      "id": "wp-01J...",
      "name": "workspace.nvim",
      "name_custom": false,
      "cwd": "/home/rain/.local/share/nvim/workspace.nvim",
      "anchor": "/home/rain/.local/share/nvim/workspace.nvim/DESIGN.md",
      "active_buffer": "/path/a.lua",
      "buffers": ["/path/a.lua", "/path/b.lua"]
    }
  ],
  "active_index": 0
}
```

- 不持久化 tab handle、bufnr；只存稳定 workspace ID、tab 顺序、绝对路径。
- `anchor` 用于在 tab 顺序不一致时辅助匹配（可选）；`active_buffer` 用于辅助匹配和
  恢复焦点（窗口布局仍交给 session 管理器）。
- `buffers` 只保存能在重启后定位的文件（普通文件、acwrite 等）；未命名临时 buffer、
  终端内容不做保证，文档明确。
- 可将 terminal buffer 排除在持久化 membership 之外（session 自身能否恢复 terminal
  取决于 `sessionoptions`）。
- 不复制窗口布局；交给 `:mksession`。如果用户不用 session 管理器，v1 不保证窗口布局
  恢复（可以后续增加“只恢复 workspace + 空布局”的能力）。

#### 4.5.2 保存策略

优先级建议：

1. **SessionWritePost 写 sidecar**：`vim.v.this_session .. ".workspace.json"`。
   - 对 persistence.nvim、auto-session 等调用 `:mksession` 的管理器天然生效。
   - resession.nvim 不使用 `mksession`，sidecar 方案不适用，需使用它的 extension
     hooks（见 4.5.5）。
   - 用原子写；sidecar 写失败只 notify，不影响 Vim 退出。
2. **可选全局状态**：同时维护 `vim.g.WorkspaceNvimState`（JSON 字符串），在
   `sessionoptions` 包含 `globals` 时，session 文件自身携带一份元数据，便于迁移。
   - 若采用，需在每次状态变化时更新（可 debounce），或在 SessionWritePost 中更新
     （但此时 mksession 已写完，更新 global 不会进入当前 session；因此必须提前维护）。
   - `globals` 只能保存 String/Number，不能直接保存 Lua table；JSON 字符串是唯一
     现实做法。
   - 不建议 v1 同时实现两者；先做 sidecar，API 预留。
3. **API**：`workspace.session.serialize()` / `.restore(state)`，方便 session 管理器
   的 pre/post hook 手动集成。
4. **保存/恢复期间抑制事件**：参考 resession 的做法，在保存时临时设置
   `eventignore`，或使用 hydrating guard，避免 tab/cwd 切换触发状态写入。

#### 4.5.3 恢复流程（SessionLoadPost）

1. 读取 sidecar（路径由 `v:this_session` 推导）；如果没有，回退到可选的全局状态；
   如果都没有，只采纳 tab 并重新生成名称/cwd（membership 用可见 buffer）。
2. 校验版本、workspace 数量；若 sessionoptions 的 `tabpages` 被关闭，session 只有
   当前 tab，此时只能按当前 tab 尽量恢复，并 notify 用户。
3. 进入 hydrating 模式（抑制事件、禁止写盘）。
4. 清空旧 registry（这些 workspace 属于加载前的旧 session；不要触发关闭清理）。
5. 遍历当前所有 tab：
   - 匹配 snapshot：先按稳定 workspace ID（如果 session 管理器能保留），再按
     anchor/cwd，最后按 index 兜底；不要按 tab handle 匹配；
   - 创建新 workspace，写入 id、name、name_custom、cwd；
   - 对每个 saved buffer path 执行 `bufadd`（不立即加载），按保存顺序加入 membership；
   - 把 tab 中当前可见（非浮窗）的 buffer 加入 membership；
   - 设置 tabpage var 与 `t:name`；必要时用 `tcd` 重设 cwd（因为用户可能没有
     `curdir`，或 session 管理器的 cwd 恢复不完整）。
6. 对当前 tab 执行一次 scope sync，列出其成员并 unlist 其他成员；必要时恢复
   active_buffer（若它仍在窗口/列表中）。
7. 退出 hydrating；触发一次 `WorkspaceRestored` 和 `WorkspaceChanged`。
8. 整个流程幂等：SessionLoadPost 可能触发两次；用 hydrating + 最近 session 路径校验。

注意：

- sidecar 里的 buffer 在 session 中可能没有被打开窗口（mksession 不保存隐藏 unlisted
  buffer），因此必须用 `bufadd` 补回 membership；它们保持 unlisted，只有进入相应
  工作区才 listed。
- 这同时解决 resession 默认跳过 nobuflisted buffer 的问题（前提是 session 管理器
  至少恢复了 tab 布局；若它完全重建界面，需要专门的 adapter）。
- 若 session 恢复时 buffer 路径已不存在，跳过并 notify（或保留 membership 的“失效
  路径”供以后手动处理；建议 v1 跳过）。
- 只保存路径不保存内容：未保存的 modified buffer 无法恢复，这是 session 管理器的
  通用限制。

#### 4.5.4 与 persistence.nvim 的集成

当前用户的 persistence.nvim 配置：

- 保存：`VimLeavePre` → `mksession!` 到 `stdpath("state")/sessions/<cwd 编码>[%branch].vim`；
- 加载：`source` session 文件，触发 `SessionLoadPost`。

因此：

- sidecar 方案可以直接工作：`SessionWritePost` 时写 sidecar，加载时 `SessionLoadPost`
  读取。
- **需要把 `curdir` 加入 `sessionoptions`**，否则 session 自身不会保存 tcd；虽然
  sidecar 会重设 cwd，但加上 `curdir` 后恢复过程更稳定。
- persistence.nvim 的 session 文件名基于**当前 global/effective cwd**（`getcwd()`），
  当有多个工作区时，session 会以“退出时活动工作区的 cwd”命名，但内容包含所有 tab。
  这意味着从不同工作区退出可能生成不同 session 文件。需要在文档中说明；或者建议用户
  在使用 workspace.nvim 时改用固定命名/专门的 session 管理器，或后续提供
  persistence 适配器，让 session 名称不按活动 cwd 变化。
- 不要使用 scope.nvim 的 `ScopeSaveState` 流程；它与本项目重复且依赖其私有状态。

#### 4.5.5 其他 session 管理器适配（v1 仅保留通用 API）

v1 只实现 sidecar + persistence.nvim 集成并做测试；下表作为后续适配参考。

| 管理器 | 机制 | 适配方式 |
|---|---|---|
| persistence.nvim | `mksession` + `source`；`VimLeavePre` 保存；有 `PersistenceSavePre/Post`、`PersistenceLoadPre/Post` | sidecar 自动生效；可额外监听其 User 事件做校验。注意 session 文件名基于当前 effective cwd（见上） |
| auto-session | `mksession`；有 `pre_save_cmds` / `post_restore_cmds` / `save_extra_cmds` | sidecar 自动生效；或用 post_restore 调用 `workspace.session.restore*` |
| resession.nvim | 自研 JSON session，不用 mksession；保存每个 tab 的 cwd 与 window-local cwd，按顺序恢复；默认 `buf_filter` 要求 listed；有 `on_save`/`on_pre_load`/`on_post_load` extension hooks | 实现 resession extension：在 on_save 保存 workspace 名称/membership，在 on_post_load 重建；覆盖 `buf_filter` 以包含 unlisted buffer，或依赖 `bufadd` 补回。它不会保存 t: 变量，稳定 ID/sidecar 仍然是必需的 |
| nvim-possession / 其他 | 通常包一层 mksession 或 source | 通过 `SessionWritePost` / `SessionLoadPost` 或公开的 serialize/restore API 接入 |

resession 的架构值得借鉴：它显式保存 tab 顺序与每个 tab 的 cwd，用 extension 钩子
在布局恢复前后执行自定义逻辑。这比把全部内容塞进全局变量更清晰。若未来要支持
“session 中包含工作区名称并跨机器复制”，优先考虑 resession extension 或 sidecar，
而不是覆盖用户的 session 管理器。

### 4.6 命令、API 与配置

#### 4.6.1 命令（建议）

```text
:Workspace new [path] [name]    新建工作区（tab），可选设置 cwd/名称
:Workspace open [name|id|path]  打开/切换工作区；无参数时用 vim.ui.select
:Workspace list                 列出工作区（名称、cwd、buffer 数、active）
:Workspace close[!]             关闭当前工作区（! 为强关闭）
:Workspace rename [name]        重命名当前工作区；无参数时 vim.ui.input
:Workspace cwd [path]           查看/设置当前工作区 cwd（同步 tcd）
:Workspace next / prev          切换工作区（可选便捷命令）
:Workspace buffers              列出当前工作区 buffer（可选）
:Workspace save / restore       手动触发 sidecar 保存/加载（可选）
```

也可以设计成 `:Workspace <subcommand>` 单命令 + completion；实现上更整洁。建议同时
提供 Lua API，命令只是薄封装。

#### 4.6.2 Lua API（建议）

```lua
local wp = require("workspace")

wp.setup(opts)
wp.current()                 -- Workspace|nil
wp.list()                    -- Workspace[]
wp.find(id_or_name)          -- Workspace|nil
wp.new({ cwd = ..., name = ..., enter = true })
wp.open(id_or_name_or_path)
wp.close(id?, { force = false })
wp.rename(id?, name)
wp.set_cwd(id?, path)
wp.switch(id)
wp.buffers(id?)              -- bufnr[]
wp.attach_buffer(bufnr, id?)
wp.detach_buffer(bufnr, id?)
wp.cwd(id?)                  -- string
wp.refresh()                 -- 手动 reconcile
wp.health()
require("workspace.session").serialize() / .restore(state) / .save_to(path) / .load_from(path)
```

用户事件（`User` autocmd，按需）：

- `WorkspaceNvimOpened`
- `WorkspaceNvimEntered`
- `WorkspaceNvimChanged`
- `WorkspaceNvimClosed`
- `WorkspaceNvimBufferAttached` / `BufferDetached`
- `WorkspaceNvimRestored`

事件本身无 payload；提供 `wp.current()` / `wp.list()` 供回调查询。若使用 0.12，可
考虑 `nvim_exec_autocmds` 的 data 能力，但为了兼容性不作为必需。

#### 4.6.3 配置草案

```lua
require("workspace").setup({
  new_tab_cwd = "inherit",        -- inherit | global
  buffer_scope = {
    enabled = true,
    exclude_buftypes = { nofile = true, prompt = true, quickfix = true },
    exclude_filetypes = {},
  },
  cwd = {
    sync_global_cd = true,        -- :cd 写回当前 workspace
  },
  tabline = {
    enabled = "auto",             -- auto | true | false
    show_index = true,
    show_modified = true,
  },
  close = {
    delete_unmodified = true,     -- 独占且未修改：删除
    modified = "prompt",          -- :WorkspaceClose 弹窗；原生关闭则保留
    notify = true,
  },
  session = {
    enabled = true,               -- sidecar + SessionWritePost/LoadPost
  },
  telescope = {
    load_extension = true,        -- setup 时自动 load_extension("workspace")
  },
  notify = vim.log.levels.WARN,
})
```

#### 4.6.4 Health check

`:checkhealth workspace` 应检查：

- Neovim 版本是否满足最低要求；
- `sessionoptions` 是否包含 `tabpages`（多 tab 恢复必需）、`curdir`（实测 tcd
  持久化必需）、`buffers`；
- `sessionoptions` 是否包含 `globals`（仅当使用 global 状态方案；sidecar 不要求）；
- `autochdir` 是否开启（建议关闭或明确警告）；
- `hidden` 是否开启（建议，非强制）；
- 是否加载了 scope.nvim（augroup `ScopeAU`，或 `package.loaded.scope`）——冲突警告；
- 重复 setup / augroup 泄漏；
- 每个 workspace 是否都有显式 tcd（`haslocaldir(-1, tabnr)`），cwd 是否存在；
- 当前 buffer/window 是否有 buffer-local / window-local cwd（`bcd`/`lcd`），提示
  effective cwd 可能与 workspace cwd 不一致；
- persistence.nvim / resession / auto-session 的检测与集成状态（可选）；
- 当前 tab 数量与 registry 是否一致，是否存在无效 tab handle / stale workspace；
- custom tabline 是否被用户覆盖（仅提示）。

### 4.7 生态集成

| 插件/功能 | 是否需要适配 | 说明 |
|---|---|---|
| bufferline.nvim | 基本不需要 | 只显示 listed buffer；buflisted 作用域直接生效。设置 `t:name` 兼容其 tabs 模式。`always_show_bufferline=false` 时空白工作区正常隐藏 |
| barbar.nvim | 不官方支持 | 它维护自己的全局 buffer order，并提供全局 bufferline；scope 曾报告顺序冲突。可工作但不要依赖其内部状态做工作区归属 |
| telescope.nvim | 提供 extension | buffers picker 自动按 listed 显示；`:Telescope workspace` 列出工作区、预览 cwd/buffer 并在回车时切换 |
| lualine.nvim | 提供组件示例 | `wp.current().name/cwd`；工作区名称/目录可作为 statusline 组件 |
| tabby.nvim | 可选替代 tabline | 它是 UI 框架；若用户使用它，禁用内置 tabline，避免两者抢 `'tabline'`。名称以本插件 sidecar 为准 |
| bufferline tabs mode / 自定义 tabline | 可选 | 内置 tabline、bufferline tabs 模式、tabby 三选一；用 `t:name` 兼容 |
| persistence.nvim | 自动 sidecar 集成 | 需注意其 session 命名基于当前 effective cwd；建议加 `curdir`；可用 `Persistence*` 事件做校验 |
| auto-session | 自动 sidecar 集成 | mksession 类；可用 post_restore hook 调用 restore API |
| resession.nvim | 需要 extension | 不用 mksession；用 `on_save`/`on_post_load` 保存/恢复 workspace 元数据；默认 buf_filter 会跳过 nobuflisted，需覆盖或依赖 bufadd 补回 |
| workspaces.nvim | 可选组合 | 仅目录注册表和 picker；可作为 `:Workspace open` 的前端之一，不提供 buffer 归属 |
| neo-tree / oil / netrw | 无需强绑定 | 它们的窗口/状态通常在 tab 内；tab-local cwd 可被多数使用 `getcwd()` 的代码感知 |
| terminal | 纳入/不纳入可配置 | tab 关闭会结束终端；session 恢复终端依赖 `terminal` sessionoption |
| quickfix | 不支持隔离 | 全局数据结构；后续可做 per-workspace 快照，但不在 v1 |
| LSP / DAP | 不隔离 | LSP 按 buffer/root attach；改变 tcd 不会 re-root 已有 client；DAP 会话全局；文档明确边界 |
| scope.nvim | **冲突，需禁用** | 两者都切换 buflisted，且 sessionoptions 需求不同；health 检测并提示迁移 |

### 4.8 从当前配置迁移的建议

当前 `~/.config/nvim` 已启用 scope.nvim，且 `plugin/scope.lua` 把 `sessionoptions`
改成了 `{ "buffers", "tabpages", "globals" }`。迁移到 workspace.nvim 时建议：

1. 移除 scope.nvim 插件及 `plugin/scope.lua`（其中还有重复的
   `require("scope").setup({})`），并移除 telescope 的 `scope` extension 加载。
2. 调整 `sessionoptions`，至少包含：
   `buffers,tabpages,curdir,globals`（以及用户原有需要的 `folds/help/terminal` 等）。
   `curdir` 是 tab-local cwd 能被 `:mksession` 保存的必要条件。
3. 建议设置 `vim.o.hidden = true`，以保留隐藏 buffer 的 undo。
4. 保留 persistence.nvim、bufferline、telescope；workspace.nvim 通过 listed 作用域
   与 bufferline/telescope 协作，通过 SessionWritePost/SessionLoadPost 与
   persistence.nvim 协作。
5. 保留 lualine，可通过其组件显示 workspace 名称；不需要改动 bufferline 的
   `mode = "buffers"`。
6. 安装 workspace.nvim 后先跑 `:checkhealth workspace`，确认无 scope 冲突、
   sessionoptions 完整、registry 与 tab 一致。

---

## 5. 已确认决策

### 5.1 Tab 语义：所有 tab 自动成为工作区（已确认）

包括 `:tabnew`、`:tab split`、`:tab help`、terminal、`<C-w>T` 产生的 tab。
语义一致、实现简单；临时 tab 也会参与 buffer 作用域和关闭策略。不再提供
`managed_only` 混合模式作为 v1 选项。

### 5.2 Buffer 隔离：逻辑隔离 buflisted（已确认）

- 显式 membership（`t:workspace_nvim` + Lua 索引）是权威；
- `buflisted` 只是 UI 与原生命令（`:ls`/`:bnext`/bufferline/telescope）的投影；
- buffer 保持 loaded，保留 undo/LSP（建议 `hidden=true`）；
- 不默认 unload/wipe；不实现 strict 模式。

### 5.3 关闭工作区：删除独占 buffer + 未保存确认（已确认）

关闭策略如下，仅适用于**用户主动关闭工作区**；session 恢复/退出时不执行删除：

1. **共享 buffer**：永远不删除（仍被其他 workspace 引用）。
2. **独占且未修改**：直接删除，不弹窗。
3. **独占且 modified**：
   - 通过 `:WorkspaceClose` 关闭时，先弹窗三选一：
     - 取消关闭；
     - 放弃修改并关闭（删除 modified 独占 buffer）；
     - 保留 buffer 并关闭（modified 的独占 buffer 变为隐藏/临时孤儿，不删除）。
   - 通过原生 `:tabclose`、鼠标、其他插件关闭时：**`TabClosedPre` 无法取消关闭**，
     因此不删除 modified buffer，而是保留为隐藏 buffer 并 notify；未修改的独占
     buffer 仍按策略在关闭后清理。
4. **弹窗触发条件**：只有存在 modified 的独占 buffer 时才弹窗；全部未修改则直接
   删除并关闭。
5. 删除/清理必须在关闭后调度执行，避免在 `TabClosedPre` 的 layout 锁定阶段操作
   buffer；执行前再次检查 modified 状态，防止竞争导致数据丢失。
6. 退出 Neovim、加载 session、关闭最后 tab 导致退出等路径，不执行 workspace
   buffer 删除；由 session 管理器负责持久化。

这是“删除独占 buffer”与“原生关闭无法拦截”的折中：插件命令能提供完整确认，原生
关闭路径优先保证数据安全。

### 5.4 CWD：`:cd` 写回当前工作区（默认采用）

`:cd` 只影响当前工作区，自动重新锁定 tcd；`:lcd`/`:bcd` 保留 Neovim 原生语义，
不纳入 workspace cwd，health 中提示。此项未单独提问，按推荐方案执行。

### 5.5 Session 持久化：sidecar + persistence.nvim（已确认）

- v1 保留现有 persistence.nvim；sidecar JSON 与 `SessionWritePost`/`SessionLoadPost`
  集成，保存名称、cwd、稳定 ID、buffer 路径、active buffer；
- `sessionoptions` 必须加入 `curdir`；
- 需要为 persistence.nvim 做集成测试；
- resession extension / auto-session 专属适配不在 v1 必做范围，保留通用
  serialize/restore API；后续再补。

### 5.6 最低 Neovim 版本：0.12+（已确认）

直接使用 `TabClosedPre`、`SessionLoadPre`、`nvim_open_tabpage`，不实现旧版本
fallback；CI 跑 0.12.x + nightly，后续如果扩大兼容面再单独设计降级路径。

---

## 6. 已知边界与风险

1. **不是真正隔离**：所有工作区共享同一个 Neovim 进程、全局状态、寄存器、命令历史、
   quickfix、诊断列表、DAP、部分插件单例；unlisted buffer 仍可被 API 访问。同一文件
   在两个工作区是同一个 buffer，共享 undo 树、buffer-local 变量、LSP attachment 和
   诊断；Neovim 不提供 tab 级 buffer 身份隔离。
2. **外部进程 cwd**：`:!`、`:terminal` 通常使用窗口有效 cwd，但 `uv.cwd()`、未显式
   传 `cwd` 的 `jobstart`、部分插件的 shell 调用使用进程全局 cwd。实际表现要逐插件
   验证；工作区只能保证 Neovim 的四级 cwd 语义（buffer/window/tab/global）。
3. **LSP 根目录**：若用户配置里的 `root_dir` 来自 `vim.fn.getcwd()`，启动时通常正确；
   但已启动的 LSP client 不会因工作区切换或 tcd 改变而 re-root；共享 buffer 会共享
   client。需要用户显式重启 LSP 的插件/命令自行处理。
4. **buflisted 的生态副作用**：切换工作区会触发 BufAdd/BufDelete，可能触发第三方
   autosave、bufferline 重绘、session 过滤等。需要 guard、文档和 health 提示；必要时
   提供 UI-only 模式。
5. **session 管理器差异**：不同管理器的 session 恢复方式、buffer 过滤、tabpage 支持
   不同；sidecar 只能解决元数据，无法修复管理器本身的布局恢复问题。resession 需要
   extension，persistence/auto-session 可以走 sidecar。需要适配器与 known-issues 文档。
6. **mksession 不保存隐藏 unlisted buffer**：已实测；sidecar 必须保存路径并 `bufadd`
   补回，否则非活动工作区的隐藏 buffer 会丢失（tabscope.nvim 的 README 也有同样警告）。
7. **sessionoptions 缺少 `curdir` 会丢失 tcd**：已实测；health 检查 + sidecar 重设。
8. **tabpage 变量不持久化**：不能把名称/ID 仅存放在 `t:` 中；运行时可以放，恢复时要
   sidecar。`t:name` 也不会随 session 保存。
9. **未命名/终端 buffer**：无法通过路径恢复；未保存内容也无法恢复，这是 session 的
   固有限制。
10. **scope.nvim 冲突**：同用 buflisted 管理会相互覆盖；必须禁用，迁移时移除其
    `sessionoptions` 配置（当前用户配置中的 sessionoptions 也缺少 `curdir`）。
11. **autochdir / window-local / buffer-local cwd**：与工作区 cwd 概念天然冲突；
    建议关闭 autochdir；`lcd` 视为窗口内部状态；`bcd` 会跨 tab 影响共享 buffer，
    默认不支持，不纳入 workspace cwd，只做提示。
12. **tab 作为临时工作区**：`:tab split`、`:tab sb`、`:tab help`、`<C-w>T` 都会创建
    新 tab；新 tab 会成为新工作区并共享相应 buffer。这是语义选择，需要在 README 中
    说明，不要试图拦截原生命令。
13. **tab handle 不连续**：关闭/重排后 handle 可能为 4、5、6；不能做数组索引或假定
    `tabnr - 1`，必须用 tabpage API + tabpage 变量。
14. **性能与内存**：保留所有工作区的 loaded buffer 会增加内存；buflisted 切换会触发
    事件。对多数用户可接受；极端规模需要 benchmark 和可选 unload 策略。
15. **UI 插件差异**：bufferline/barbar 是全局 bufferline；barbar 有自己的顺序状态，
    与按 tab 管理 buffer 的方案不天然兼容；tabby 等 tabline 插件也可能与本插件争夺
    `'tabline'`。UI 适配需要在文档中明确。

---

## 7. 测试与验收

### 7.1 自动化测试（headless Neovim）

建议使用 `mini.test` 或 plenary busted；测试必须跑真实 tab/window/buffer 行为，
不能只 mock Lua 表。

核心用例：

1. 初始只有一个 tab：采纳、命名、锁定 tcd，membership 包含当前 buffer。
2. `:tabnew`：cwd 继承正确；名称不重复；切换后 buffer 列表正确。
3. 三个工作区分别打开不同文件：每次 tab 切换后：
   - 当前 workspace 的 buffer listed；
   - 其他 workspace 的专属 buffer unlisted；
   - bufferline 依据的 `getbufinfo({ buflisted = 1 })` 集合正确。
4. 同一文件在两个工作区打开：membership 共享；关闭一个工作区不影响另一个；
   `buflisted` 仍正确。
5. 用户 `:bdelete` / `:bwipeout`：membership 清理；插件自身的 unlist 不触发清理。
6. `DirChanged`：
   - 用户 `:tcd` 更新 cwd；
   - 用户 `:cd` 写回并重新锁定；
   - 用户 `:tcd!` 后恢复/重新锁定；
   - 用户 `:lcd` / `:bcd` 不破坏 workspace cwd（effective cwd 可不同）；
   - `changed_window=true` 的 tab 切换事件被忽略。
7. `nvim_win_call` 修改非当前 tab 的 tcd：焦点不变、事件不递归、值正确。
8. tab 关闭（当前/非当前/不是最后一个）：
   - workspace 移除；
   - 独占且未修改的 buffer 被删除；
   - 共享 buffer 永不删除；
   - modified 独占 buffer：`:WorkspaceClose` 的取消/放弃/保留三条路径；
   - 原生关闭 modified 的独占 buffer：不删除，保留为隐藏并 notify；
   - 未修改时不应弹窗；
   - session 加载/退出路径不触发删除；
   - 不产生悬空 handle；
   - 关闭/重开 tab 造成 handle 不连续后仍正确。
9. tab 重排（`:tabmove`）后工作区名称/cwd/buffer 仍绑定正确。
10. 原生操作：
    - `:tab sb`、`<C-w>T`、在另一个 tab `:buffer N` 后，新 tab 的 membership 正确，
      原 tab 仍保留共享 buffer；
    - `:tab help` / `:tab split` 成为新工作区且不破坏原有工作区。
11. 会话往返（子进程测试）：
    - 两个 tab、各自 cwd、名称、buffer membership；
    - 非活动工作区中存在无窗口、unlisted、甚至 unloaded 的 buffer；
    - 保存、退出、重新启动并 source session；
    - 验证名称、cwd、tab 顺序、membership、listed 状态、active buffer；
    - 分别在 `sessionoptions` 有/无 `curdir` 的情况下测试（有 curdir 时 session 自身
      会保存 tcd；无 curdir 时依赖 sidecar）；
    - 空工作区（只有空 tab）+ 删除文件的路径。
12. sessionoptions 缺少 `tabpages`：健康退化、只恢复一个 tab、不崩溃。
13. setup 幂等；augroup 不重复；插件 reload 后从 t: 记录识别已有工作区。
14. scope.nvim 冲突检测（augroup 存在时 health 报错）。
15. 无效 cwd / 目录被删除：不崩溃、通知、回退策略。
16. 大量 tab/buffer 的 smoke test（如 20 tabs × 50 buffers）无卡死、状态一致。
17. session 管理器集成测试（安装可用时）：
    - persistence.nvim：保存/加载、session 命名行为、`curdir`；
    - resession：默认 buf_filter 下隐藏 buffer 是否被补回、extension 恢复；
    - auto-session：post-restore hook。
18. 在保存/退出过程中（VimLeavePre/SessionWritePost）不产生递归写盘或错误。
19. tabline 名称（含 `%` 等特殊字符）、`t:name` 兼容 bufferline tabs 模式。

### 7.2 手工验收

- 配合 bufferline.nvim：切换 tab 后 bufferline 只显示当前工作区 buffer，点击/关闭正常。
- telescope buffers / find_files：只看到当前工作区 buffer；find_files 的 cwd 正确。
- lualine/statusline：显示工作区名称和 cwd；git branch 随工作区变化。
- `:terminal`、`:!pwd`、`:cd`/`:pwd` 的目录行为符合文档。
- 退出/重启恢复 session；未保存修改的提示正常。
- 关闭工作区、重新打开目录、孤儿 buffer 清理。
- 在 Neo-tree/Oil 中打开文件，membership 正确。

### 7.3 CI

- Linux 上使用 headless 集成测试；
- Neovim 矩阵：0.12.x + nightly（v1 已确认最低 0.12）；
- stylua / selene / luacheck、vimdoc 生成检查；
- 可选 macOS；Windows 路径需额外验证（sidecar 路径、fnameescape）。

---

## 8. 分阶段路线图

> **v1 交付范围 = Phase 1 + Phase 2**（含 sidecar + persistence.nvim 持久化和关闭策略）。
> Phase 3 及后续为非 v1 必做项。以下为单人或小团队估算，仅供参考。

### Phase 0：技术验证（1–2 天，已完成）

- tcd / DirChanged / buflisted / session 行为验证；
- 相关插件与 session 管理器调研；
- 决策已确认：0.12+、所有 tab、逻辑隔离、删除独占 buffer、sidecar + persistence。

### Phase 1：运行时核心（约 4–6 天）

- registry + tabpage 局部记录（t:workspace_nvim、t:name）、稳定 workspace ID；
- tab 生命周期（`TabNew`/`TabEnter`/`TabClosedPre`/`TabClosed`，0.12+）；
- cwd 管理（显式 tcd、继承、同步、win_call、bcd/lcd 策略）；
- buffer membership + buflisted 作用域（guard/清理/共享）；
- 关闭策略：独占未修改删除、modified 弹窗/保留、共享保留、退出/session guard；
- 基础命令与 Lua API；
- 简易 tabline（或先只提供名称 API）；
- health 基础检查；核心测试。

### Phase 2：持久化与生态（约 5–8 天）

- sidecar 持久化 + SessionWritePost/SessionLoadPost；
- 幂等的 session 恢复、buffer 补回、名称/active buffer 恢复；
- persistence.nvim 集成与验证（含 curdir、session 命名行为）；
- bufferline（t:name）/telescope/lualine 文档与集成；
- 关闭策略的完整测试（原生关闭无法拦截的路径、未保存 buffer）；
- 完整测试矩阵与 CI（含 handle 不连续、tab 重排、`<C-w>T` 等）。

### Phase 3：易用性与高级能力（约 4–6 天，非 v1 必做）

- 工作区 picker（vim.ui.select / telescope 扩展 / workspaces.nvim 组合）；
- 工作区名称提示、rename 交互、tabline 完善；
- 移动 buffer 到其他工作区、detach、全部工作区 buffer 浏览器
  （可参考 tabLocalBuffer.nvim 的交互）；
- 文档、`:help`、示例配置、截图/GIF；
- 性能 benchmark 与优化。

### 后续（非 v1）

- resession.nvim extension、auto-session 专属适配；
- strict/unload buffer 模式、UI-only 模式；
- 已保存的工作区模板（name + cwd + session），用于重新打开项目；
- 项目根自动识别（参考 vim-tabws/nvim-contabs），但不覆盖原生命令；
- 每工作区独立 quickfix/location list/tag stack 快照；
- 每工作区 LSP 生命周期管理；
- 真正进程隔离的 RPC 方案（独立项目级方案）。

---

## 9. 决策记录与延期项

| 决策 | 结果 |
|---|---|
| Buffer 隔离 | 逻辑隔离（显式 membership + `buflisted` 投影）；不建议 unload/wipe |
| 关闭策略 | 删除独占且未修改的 buffer；modified 独占 buffer 在 `:WorkspaceClose` 中弹窗，原生关闭时保留；共享 buffer 永不删除 |
| 持久化 | v1 使用 sidecar + SessionWritePost/SessionLoadPost，保留 persistence.nvim；`curdir` 必加 |
| 最低版本 | Neovim 0.12+，使用 `TabClosedPre`/`SessionLoadPre`/`nvim_open_tabpage`，不做旧版 fallback |
| Tab 语义 | 所有 tab 自动成为工作区（含 `:tab help`、`:tab split`、terminal、`<C-w>T`） |
| CWD | `:cd` 写回当前工作区；`:lcd`/`:bcd` 保留原生语义、不纳入 workspace cwd |

v1 暂缓（后续再评估）：

- resession.nvim extension、auto-session 专属适配（v1 只保留通用 API）；
- strict/unload buffer 模式、UI-only 模式；
- 已保存的工作区模板、项目根自动识别；
- 每工作区 quickfix/location list/tag stack、LSP 生命周期；
- 进程级隔离（RPC 多实例）。

---

## 10. 参考资料

**Neovim 文档（本机 `$VIMRUNTIME/doc`）**

- `tabpage.txt`：tabpage 模型、`:tcd`/`:lcd`、`setting-tabline`
- `editing.txt`：`current-directory`，四级 cwd 与优先级
- `vimfn.txt`：`getcwd()`、`haslocaldir()`、`gettabinfo()`
- `autocmd.txt`：`TabNew`、`TabEnter`、`TabClosed`、`TabClosedPre`、
  `SessionLoadPre/Post`、`SessionWritePost`、`DirChanged`
- `options.txt`：`sessionoptions`（尤其 `tabpages` / `curdir` / `buffers` / `globals`）
- `api.txt`：`nvim_win_call()`、`nvim_tabpage_set_var()`、`nvim_open_tabpage()`

**Neovim 在线文档与 issue**

- <https://neovim.io/doc/user/tabpage.html>
- <https://neovim.io/doc/user/editing.html#current-directory>
- <https://neovim.io/doc/user/options.html#'sessionoptions'>
- <https://neovim.io/doc/user/starting.html#%3Amksession>
- buffer groups/namespaces 讨论：<https://github.com/neovim/neovim/issues/29941>
- `tcd` + `arglocal` session 路径 bug（0.11.3 修复）：
  <https://github.com/neovim/neovim/issues/34405>

**相关插件**

- scope.nvim：<https://github.com/tiagovla/scope.nvim>
  - session handle bug：<https://github.com/tiagovla/scope.nvim/issues/43>
  - 隐藏 buffer：<https://github.com/tiagovla/scope.nvim/issues/28>
  - `:buffer N` / `:tab sb` / `<C-w>T`：
    <https://github.com/tiagovla/scope.nvim/issues/14>、
    <https://github.com/tiagovla/scope.nvim/issues/2>、
    <https://github.com/tiagovla/scope.nvim/issues/25>
- tabscope.nvim：<https://github.com/backdround/tabscope.nvim>
- tabLocalBuffer.nvim：<https://github.com/akasataikisiti/tabLocalBuffer.nvim>
- vim-tabws：<https://github.com/s1341/vim-tabws>
- bufferline.nvim：<https://github.com/akinsho/bufferline.nvim>
- barbar.nvim 与 scope 的顺序问题：<https://github.com/romgrk/barbar.nvim/issues/556>
- tabby.nvim：<https://github.com/nanozuki/tabby.nvim>
- workspaces.nvim：<https://github.com/natecraddock/workspaces.nvim>
- nvim-contabs：<https://github.com/m00qek/nvim-contabs>

**本机已安装源码（用于验证机制）**

- scope.nvim：`~/.local/share/nvim/scope.nvim/lua/scope/{core,session,utils,config}.lua`
- bufferline.nvim：`lua/bufferline/utils/init.lua` 的 `get_valid_buffers` 只取 listed；
  `lua/bufferline/buffers.lua` 的 `get_components` 使用该集合
- telescope.nvim：`lua/telescope/builtin/__files.lua` 过滤 `buflisted`
- persistence.nvim：`lua/persistence/init.lua`，`VimLeavePre` + `mksession!` + `source`
  （触发 SessionWritePost/SessionLoadPost）

**Session 管理器架构参考**

- resession.nvim：<https://github.com/stevearc/resession.nvim>
- auto-session：<https://github.com/rmagatti/auto-session>
- persistence.nvim：<https://github.com/folke/persistence.nvim>

**本地实测（临时脚本，不入库）**

- tcd 继承、`:cd` 清除本地目录、`nvim_win_call` 设置非当前 tab cwd；
- `DirChanged` scope / `changed_window` 事件顺序；
- tab close 的 `TabClosedPre`/`TabClosed` 参数与 handle 不连续；
- `mksession` 对 `curdir`、tabpage 变量、隐藏 unlisted buffer 的保存行为；
- `buflisted` 切换触发的 BufAdd/BufDelete，及 bufferline/telescope 的过滤依据。

---

## 11. 一句话设计原则

> **用 tabpage 承载窗口布局，用 `:tcd` 承载 cwd，用显式 membership（tabpage 局部记录 +
> 稳定 ID）保存归属，用 `buflisted` 呈现 buffer 投影，用 sidecar 持久化名称/cwd/
> buffer 路径；不把“推导状态”当作权威状态。**
