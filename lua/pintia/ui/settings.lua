--- :PintiaSetup — edit the persisted plugin options in a floating menu.
---
--- Changes are written to stdpath('data')/pintia/config.json and take effect
--- immediately (they outrank setup() opts; an empty input restores the default).
local config = require('pintia.config')

local M = {}

local ns = vim.api.nvim_create_namespace('pintia_settings')

local FIELDS = {
  { key = 'workdir', label = '工作区目录', hint = '题目与样例的落盘位置' },
  { key = 'session_file', label = '会话文件(session.json)', hint = '登录 cookie jar 路径' },
  { key = 'picker', label = '列表界面', kind = 'enum', values = { 'auto', 'builtin', 'ui' } },
  { key = 'command_prefix', label = '命令前缀', kind = 'enum', values = { 'Pintia', 'PTA' }, hint = ':Pintia… 或 :PTA…，改后立即生效（旧前缀命令注销）' },
  { key = 'default_language', label = '默认语言', hint = '扩展名判断不出时使用' },
  { key = 'poll_interval', label = '轮询间隔(ms)', kind = 'number' },
  { key = 'judge_timeout', label = '判题超时(秒)', kind = 'number' },
}

local WIDTH = 78

local function pad(text, width)
  local fill = width - vim.api.nvim_strwidth(text)
  return fill > 0 and (text .. string.rep(' ', fill)) or text
end

local function row_text(field, value)
  return string.format('  %-14s %s', field.label, tostring(value))
end

function M.open()
  local state = { selected = 1 }

  local function rows()
    local options = config.get()
    local out = {}
    for _, field in ipairs(FIELDS) do
      out[#out + 1] = { text = row_text(field, options[field.key]), field = field }
    end
    return out
  end

  state.rows = rows()

  local height = math.min(#state.rows + 5, vim.o.lines - 4)
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
    title = ' pintia 设置 ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  local function render()
    local lines = {}
    for _, row in ipairs(state.rows) do
      lines[#lines + 1] = pad(row.text, width - 2)
    end
    lines[#lines + 1] = ''
    local field = state.rows[state.selected] and state.rows[state.selected].field
    lines[#lines + 1] = '  ' .. (field and field.hint or '')
    lines[#lines + 1] = '  配置文件 ' .. config.config_path()
    lines[#lines + 1] = '  j/k 选择 · CR 修改 · 空输入=恢复默认 · q 关闭'

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i = #state.rows + 1, #lines do
      vim.api.nvim_buf_add_highlight(buf, ns, 'Comment', i - 1, 0, -1)
    end
    vim.api.nvim_buf_add_highlight(buf, ns, 'PmenuSel', state.selected - 1, 0, -1)
    pcall(vim.api.nvim_win_set_cursor, win, { state.selected, 0 })
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  local function refresh()
    state.rows = rows()
    render()
  end

  local function apply(field, value)
    local ok, err = config.set_saved(field.key, value)
    if not ok then
      vim.notify('pintia: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify(
      string.format('pintia: %s → %s（已保存，立即生效）', field.label, tostring(config.get()[field.key])),
      vim.log.levels.INFO
    )
    refresh()
    if field.key == 'command_prefix' then
      require('pintia').register_commands()
    end
  end

  local function edit(row)
    local field = row.field
    if field.kind == 'enum' then
      -- cycle: fastest for a three-value switch
      local current = config.get()[field.key]
      local index = 1
      for i, value in ipairs(field.values) do
        if value == current then
          index = i
        end
      end
      apply(field, field.values[(index % #field.values) + 1])
      return
    end

    vim.ui.input({
      prompt = field.label .. '（空=恢复默认）: ',
      default = tostring(config.get()[field.key]),
    }, function(input)
      if input == nil then
        return
      end
      input = vim.trim(input)
      if input == '' then
        apply(field, nil)
        return
      end
      if field.kind == 'number' then
        local number = tonumber(input)
        if number == nil or number <= 0 then
          vim.notify('pintia: 需要一个正整数', vim.log.levels.WARN)
          return
        end
        apply(field, math.floor(number))
        return
      end
      apply(field, vim.fn.expand(input))
    end)
  end

  local map = function(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map('j', function()
    state.selected = math.min(state.selected + 1, #state.rows)
    render()
  end, '下一个')
  map('<Down>', function()
    state.selected = math.min(state.selected + 1, #state.rows)
    render()
  end, '下一个')
  map('k', function()
    state.selected = math.max(state.selected - 1, 1)
    render()
  end, '上一个')
  map('<Up>', function()
    state.selected = math.max(state.selected - 1, 1)
    render()
  end, '上一个')
  map('<CR>', function()
    local row = state.rows[state.selected]
    if row then
      edit(row)
    end
  end, '修改')
  map('q', close, '关闭')
  map('<Esc>', close, '关闭')

  render()
end

return M
