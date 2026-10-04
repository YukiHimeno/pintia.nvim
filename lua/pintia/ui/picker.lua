--- Built-in floating picker: type to filter, <C-n>/<C-p> choose, <CR> open.
--- Kept dependency-free; works the same everywhere (telescope/fzf-lua users can
--- still drive everything through the :Pintia* commands).
local config = require('pintia.config')

local M = {}

-- Pickers we can hand `vim.ui.select` to when the user has one loaded. Nothing
-- is required: without any of these the bundled picker below takes over.
local PROVIDERS = { 'snacks', 'telescope', 'fzf-lua' }

local function provider_loaded()
  for _, name in ipairs(PROVIDERS) do
    if package.loaded[name] ~= nil then
      return true
    end
  end
  return false
end

--- Effective picker backend: 'builtin' or 'ui'.
function M.mode()
  local mode = config.get().picker or 'auto'
  if mode ~= 'builtin' and mode ~= 'ui' then
    mode = provider_loaded() and 'ui' or 'builtin'
  end
  return mode
end

--- Dispatcher used by every list in the plugin.
--- opts: { title, hint, items, fetch_page?, on_select, secondary_key?, on_secondary?, secondary_label? }
function M.select(opts)
  if M.mode() == 'ui' then
    local labels = vim.tbl_map(function(item)
      return item.label
    end, opts.items)
    vim.ui.select(labels, { prompt = opts.title, kind = 'pintia' }, function(_, idx)
      if idx == nil then
        return
      end
      local item = opts.items[idx]
      if item ~= nil then
        vim.schedule(function()
          opts.on_select(item)
        end)
      end
    end)
    return
  end
  M.open(opts)
end

local ns = vim.api.nvim_create_namespace('pintia_picker')

local function subsequence_match(needle, haystack)
  needle = needle:lower()
  haystack = haystack:lower()
  local pos = 1
  for ch in needle:gmatch('.') do
    pos = haystack:find(ch, pos, true)
    if not pos then
      return false
    end
    pos = pos + 1
  end
  return true
end

--- opts:
---   title     window title
---   hint      one-line hint under the prompt
---   items     initial { { label = string, data = any }, ... }
---   fetch_page(page, cb)  optional pager; cb(items, max_page)
---   on_select(item)
---   on_secondary(item)    optional <C-s> action
---   secondary_label       hint text for the secondary action
function M.open(opts)
  local state = {
    items = opts.items or {},
    filtered = {},
    selected = 1,
    filter = '',
    page = 1,
    max_page = 1,
    loading = false,
  }
  state.filtered = state.items

  local width = math.min(math.max(opts.width or 90, 60), vim.o.columns - 6)
  local height = math.min(math.max(opts.height or 22, 8), vim.o.lines - 6)

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
    title = ' ' .. (opts.title or 'pintia') .. ' ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  local function hint_line()
    local parts = { string.format('%d/%d', #state.filtered, #state.items) }
    if opts.fetch_page then
      parts[#parts + 1] = string.format('第 %d/%d 页 <C-f>/<C-b>', state.page, state.max_page)
    end
    parts[#parts + 1] = 'j/k·↑↓ 选择'
    parts[#parts + 1] = '<CR> 打开'
    if opts.on_secondary then
      parts[#parts + 1] = (opts.secondary_label or '<C-s> 操作')
    end
    parts[#parts + 1] = 'Esc 浏览/关闭'
    return ' ' .. table.concat(parts, ' · ')
  end

  --- The prompt line (row 0) is owned by the user while typing: rewriting it
  --- mid-edit cuts multi-byte input apart, so only the rows below it are drawn
  --- here. The prompt is written once at open time.
  local function render()
    local header = { ' ' .. (opts.hint or ''), hint_line(), string.rep('─', width - 2) }
    local body = {}
    for _, item in ipairs(state.filtered) do
      body[#body + 1] = '  ' .. item.label
    end
    if state.loading then
      body[#body + 1] = '  ⏳ 加载中…'
    end

    vim.api.nvim_buf_set_lines(buf, 1, -1, false, vim.list_extend(header, body))
    vim.bo[buf].modified = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if state.selected >= 1 and state.selected <= #state.filtered then
      local line_nr = 3 + state.selected -- 0-based row of the item
      vim.api.nvim_buf_add_highlight(buf, ns, 'PmenuSel', line_nr, 0, -1)
    end
  end

  local function refilter()
    if state.filter == '' then
      state.filtered = state.items
    else
      local out = {}
      for _, item in ipairs(state.items) do
        if subsequence_match(state.filter, item.label) then
          out[#out + 1] = item
        end
      end
      state.filtered = out
    end
    state.selected = math.min(math.max(state.selected, 1), math.max(#state.filtered, 1))
    render()
  end

  local function close()
    -- The picker runs in insert mode (typing filters); leaving it on would leak
    -- into whatever window the action opens next.
    pcall(vim.cmd, 'stopinsert')
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  local function selected_item()
    return state.filtered[state.selected]
  end

  local function load_page(page)
    if not opts.fetch_page or state.loading then
      return
    end
    state.loading = true
    render()
    opts.fetch_page(page, function(items, max_page)
      state.loading = false
      state.page = page
      state.max_page = max_page or state.max_page
      state.items = items
      state.selected = 1
      refilter()
    end)
  end

  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  local function move(delta)
    state.selected = math.min(math.max(state.selected + delta, 1), math.max(#state.filtered, 1))
    render()
  end

  local function choose()
    local item = selected_item()
    if item then
      close()
      vim.schedule(function()
        opts.on_select(item)
      end)
    end
  end

  local function secondary()
    local item = selected_item()
    if item and opts.on_secondary then
      close()
      vim.schedule(function()
        opts.on_secondary(item)
      end)
    end
  end

  -- insert 模式：输入即过滤，方向键/<C-n>/<C-p> 移动，回车打开
  map('i', '<CR>', choose, '打开')
  map('i', '<C-n>', function() move(1) end, '选择下一项')
  map('i', '<C-p>', function() move(-1) end, '选择上一项')
  map('i', '<Down>', function() move(1) end, '选择下一项')
  map('i', '<Up>', function() move(-1) end, '选择上一项')
  map('i', '<Esc>', function() vim.cmd('stopinsert') end, '进入浏览')

  -- normal 模式：j/k/方向键 移动，CR 打开，i 回到过滤输入
  map('n', 'j', function() move(1) end, '选择下一项')
  map('n', 'k', function() move(-1) end, '选择上一项')
  map('n', '<Down>', function() move(1) end, '选择下一项')
  map('n', '<Up>', function() move(-1) end, '选择上一项')
  map('n', '<CR>', choose, '打开')
  map('n', 'i', function()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '> '
    pcall(vim.api.nvim_win_set_cursor, vim.api.nvim_get_current_win(), { 1, #line })
    vim.cmd('startinsert!')
  end, '返回过滤输入')
  map('n', '<Esc>', close, '关闭')
  map('n', 'q', close, '关闭')

  local secondary_key = opts.secondary_key or '<C-s>'
  map('i', secondary_key, secondary, opts.secondary_label or '次操作')
  map('n', secondary_key, secondary, opts.secondary_label or '次操作')

  map('i', '<C-f>', function()
    load_page(state.page + 1)
  end, '下一页')
  map('i', '<C-b>', function()
    load_page(math.max(state.page - 1, 1))
  end, '上一页')
  map('n', '<C-f>', function()
    load_page(state.page + 1)
  end, '下一页')
  map('n', '<C-b>', function()
    load_page(math.max(state.page - 1, 1))
  end, '上一页')

  -- typing filters
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = buf,
    callback = function()
      local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
      local filter = line:sub(3)
      if filter ~= state.filter then
        state.filter = filter
        refilter()
      end
    end,
  })

  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '> ' })
  render()
  vim.cmd('startinsert!')
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 2 })
    end
  end)

  return { close = close }
end

return M
