--- Floating windows used for progress, verdicts and local test results.
local M = {}

local function centered_config(width, height)
  local total_w = vim.o.columns
  local total_h = vim.o.lines - vim.o.cmdheight
  width = math.min(width, total_w - 4)
  height = math.min(height, total_h - 4)
  return {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((total_h - height) / 2) - 1, 0),
    col = math.floor((total_w - width) / 2),
    style = 'minimal',
    border = 'rounded',
  }
end

--- Open a floating window showing `lines`. Returns { win, buf, set, close }.
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or {})
  vim.bo[buf].modifiable = true
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  local cfg = centered_config(opts.width or 76, opts.height or 20)
  if opts.title then
    cfg.title = ' ' .. opts.title .. ' '
    cfg.title_pos = 'center'
  end

  local win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[win].wrap = opts.wrap ~= false
  vim.wo[win].linebreak = true

  local function set(lines)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    -- keep the tail visible, like a log
    if vim.api.nvim_win_is_valid(win) and opts.follow ~= false then
      local last = vim.api.nvim_buf_line_count(buf)
      pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if opts.on_close then
      opts.on_close()
    end
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, vim.tbl_extend('force', map_opts, { desc = '关闭' }))
  vim.keymap.set('n', '<Esc>', close, vim.tbl_extend('force', map_opts, { desc = '关闭' }))
  vim.keymap.set('n', 'g?', function()
    vim.notify(table.concat({
      'q / Esc  关闭',
      'j / k    滚动',
    }, '\n'))
  end, map_opts)

  return { win = win, buf = buf, set = set, close = close }
end

return M
