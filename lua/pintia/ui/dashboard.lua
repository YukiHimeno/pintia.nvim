--- The floating dashboard behind `:Pintia`: one hub, driven with j/k + Enter.
---
--- Every ecosystem touch point (pickers etc.) is optional; this window itself
--- only uses core Neovim APIs so it behaves the same in any setup.
local api = require('pintia.api')
local config = require('pintia.config')
local history = require('pintia.history')
local workspace = require('pintia.workspace')

local M = {}

local ns = vim.api.nvim_create_namespace('pintia_dashboard')

local WIDTH = 66

local function pad(text, width)
  local fill = width - vim.api.nvim_strwidth(text)
  return fill > 0 and (text .. string.rep(' ', fill)) or text
end

--- Build the rows. Each row is { text, kind = 'header'|'action'|'info', action? }.
local function build_rows(actions, account)
  local rows = {}
  local function header(text)
    rows[#rows + 1] = { text = ' ' .. text, kind = 'header' }
  end
  local function action(text, fn)
    rows[#rows + 1] = { text = '  ' .. text, kind = 'action', action = fn }
  end
  local function info(text)
    rows[#rows + 1] = { text = '  ' .. text, kind = 'info' }
  end
  local function gap()
    rows[#rows + 1] = { text = '', kind = 'blank' }
  end

  gap()
  header('操作')
  if not account.logged_in then
    action('⚿  登录                     登录 Pintia', actions.login)
  end
  action('◈  题集                     浏览题集与题目', actions.problem_sets)
  action('▷  本地测试                 样例跑在本地编译器上', actions.test)
  action('⇧  提交                     当前文件提交并跟踪判题', actions.submit)
  action('◷  盯判题                   监视最近一次提交', actions.watch)
  action('⚙  设置                     工作区目录 / 列表界面 / 超时等', actions.settings)
  action('ℹ  状态                     账号 / 工作区一览', actions.status)
  action('✓  环境自检                 curl / 编译器 / 会话', actions.health)
  if account.logged_in then
    action('⏏  退出登录', actions.logout)
  end

  local ws = workspace.find(vim.api.nvim_buf_get_name(0)) or workspace.find(vim.fn.getcwd())
  if ws then
    gap()
    header('当前工作区')
    info(vim.trim(ws.meta.title or ''))
    local samples = workspace.read_samples(ws.dir)
    info(string.format('样例 %d 组 · %s分', #samples, tostring(ws.meta.score or '?')))
    info('源码 ' .. (workspace.find_source(ws.dir) and vim.fn.fnamemodify(workspace.find_source(ws.dir), ':t') or '（无）'))
    local verdict = history.last_verdict()
    if verdict then
      info(string.format('最近判题 #%s %s %s', tostring(verdict.sid), verdict.short or '', verdict.name or ''))
    end
  end

  local recent = history.recent(5)
  if #recent > 0 then
    gap()
    header('最近题目')
    for _, entry in ipairs(recent) do
      local label = string.format('%s %s', entry.ref.label or '', entry.title or '')
      label = vim.trim(label)
      action(label, function()
        actions.open_workspace(entry.ref, entry.title)
      end)
    end
  end

  gap()
  return rows
end

--- Open the dashboard. `actions` is the plugin module (init.lua) — passed in to
--- avoid a require cycle.
function M.open(actions)
  local account = { logged_in = false, name = '检查中…' }
  local state = {
    rows = build_rows(actions, account),
    selected = 1,
  }

  local height = math.min(#state.rows + 2, vim.o.lines - 4)
  local width = math.min(WIDTH, vim.o.columns - 4)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = true
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' pintia ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  local function selectable_indices()
    local out = {}
    for i, row in ipairs(state.rows) do
      if row.kind == 'action' then
        out[#out + 1] = i
      end
    end
    return out
  end

  local function footer(account_text)
    local text = string.format('账号 %s', account_text)
    local hint = 'j/k 移动 · CR 执行 · q 关闭'
    local fill = math.max(width - 4 - vim.api.nvim_strwidth(text) - vim.api.nvim_strwidth(hint), 1)
    return '  ' .. text .. string.rep(' ', fill) .. hint .. ' '
  end

  local function render()
    local lines = {}
    for _, row in ipairs(state.rows) do
      lines[#lines + 1] = row.kind == 'action' and pad(row.text, width - 2) or row.text
    end
    lines[#lines + 1] = footer(account.logged_in and account.name or '未登录（回车「登录」）')

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, row in ipairs(state.rows) do
      if row.kind == 'header' then
        vim.api.nvim_buf_add_highlight(buf, ns, 'Title', i - 1, 0, -1)
      elseif row.kind == 'info' or row.kind == 'blank' then
        vim.api.nvim_buf_add_highlight(buf, ns, 'Comment', i - 1, 0, -1)
      end
    end
    vim.api.nvim_buf_add_highlight(buf, ns, 'Comment', #state.rows, 0, -1)
    local indices = selectable_indices()
    local selected_row = indices[state.selected]
    if selected_row then
      vim.api.nvim_buf_add_highlight(buf, ns, 'PmenuSel', selected_row - 1, 0, -1)
      pcall(vim.api.nvim_win_set_cursor, win, { selected_row, 0 })
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  local function run(row)
    if row == nil or row.action == nil then
      return
    end
    close()
    vim.schedule(row.action)
  end

  local function move(delta)
    local indices = selectable_indices()
    if #indices == 0 then
      return
    end
    state.selected = math.min(math.max(state.selected + delta, 1), #indices)
    render()
  end

  local function current_row()
    local indices = selectable_indices()
    return state.rows[indices[state.selected]]
  end

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('j', function() move(1) end, '下一个')
  map('<Down>', function() move(1) end, '下一个')
  map('k', function() move(-1) end, '上一个')
  map('<Up>', function() move(-1) end, '上一个')
  map('<CR>', function() run(current_row()) end, '执行')
  map('q', close, '关闭')
  map('<Esc>', close, '关闭')
  map('r', function()
    close()
    M.open(actions)
  end, '刷新')

  -- mouse: click a row to run it
  map('<LeftMouse>', function()
    local line = vim.fn.getmousepos().line
    if line >= 1 and line <= #state.rows then
      run(state.rows[line])
    end
  end, '鼠标执行')

  render()

  -- account state arrives after the window is up
  api.current_user(function(err, user)
    account.logged_in = (err == nil and user ~= nil)
    account.name = account.logged_in and (user.nickname or user.email or tostring(user.id)) or '未登录（回车「登录」）'
    if err ~= nil and api.load_session() then
      require('pintia').try_auto_relogin()
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    state.rows = build_rows(actions, account)
    state.selected = math.min(state.selected, math.max(#selectable_indices(), 1))
    render()
  end)
end

return M
