local M = {}

M.defaults = {
  -- Where pulled problems, their statements and samples live.
  workdir = vim.fn.stdpath('data') .. '/pintia/workspace',
  -- JSON file holding the PTASession cookie, like the web login.
  session_file = vim.fn.stdpath('data') .. '/pintia/session.json',
  -- "Language (compiler)" label used when the extension gives no hint.
  default_language = 'C++ (g++)',
  -- Poll interval (ms) while waiting for a verdict.
  poll_interval = 2000,
  -- Give up waiting for a verdict after this many seconds.
  judge_timeout = 180,
  -- List UI: 'auto' uses snacks/telescope/fzf-lua via vim.ui.select when one is
  -- loaded, 'builtin' always uses the bundled floating picker, 'ui' always
  -- defers to vim.ui.select (whatever provides it).
  picker = 'auto',
  -- Command prefix: ':Pintia*', ':PTA*' are registered (case-sensitive command
  -- names; Neovim requires the first letter to be uppercase).
  command_prefix = 'Pintia',
}

M.options = {}

-- Values saved through :PintiaSetup. Precedence, low to high:
-- defaults < setup() opts < these persisted values.
local persisted = nil
local setup_opts = {}

--- Where :PintiaSetup writes its choices.
function M.config_path()
  return vim.fn.stdpath('data') .. '/pintia/config.json'
end

local function read_persisted()
  local path = M.config_path()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, data = pcall(function()
    local fd = io.open(path, 'r')
    local content = fd:read('*a')
    fd:close()
    return vim.json.decode(content)
  end)
  if not ok or type(data) ~= 'table' then
    return {}
  end
  return data
end

--- Persisted (user-edited) options.
function M.saved()
  if persisted == nil then
    persisted = read_persisted()
  end
  return persisted
end

--- Set one option and persist it. A nil (or default) value removes the key.
function M.set_saved(key, value)
  local saved = M.saved()
  if value == nil or value == M.defaults[key] then
    saved[key] = nil
  else
    saved[key] = value
  end

  local path = M.config_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local fd = io.open(path, 'w')
  if not fd then
    return false, '无法写入 ' .. path
  end
  local payload = next(saved) == nil and '{}' or vim.json.encode(saved)
  fd:write(payload)
  fd:close()

  M.rebuild()
  return true
end

local function ensure_dirs(options)
  vim.fn.mkdir(vim.fn.fnamemodify(options.session_file, ':h'), 'p')
  vim.fn.mkdir(options.workdir, 'p')
end

--- Recompute the effective options: defaults, then setup() opts, then saved.
function M.rebuild()
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), setup_opts, M.saved())
  ensure_dirs(M.options)
  return M.options
end

function M.setup(opts)
  setup_opts = opts or {}
  return M.rebuild()
end

function M.get()
  if vim.tbl_isempty(M.options) then
    M.rebuild()
  end
  return M.options
end

return M
