--- Recently opened problems and the latest verdict, kept next to the session file.
local config = require('pintia.config')

local M = {}

local MAX_RECENT = 15

local function file()
  return vim.fn.fnamemodify(config.get().session_file, ':h') .. '/history.json'
end

function M.load()
  local path = file()
  if vim.fn.filereadable(path) == 0 then
    return { recent = {} }
  end
  local ok, data = pcall(function()
    local fd = io.open(path, 'r')
    local content = fd:read('*a')
    fd:close()
    return vim.json.decode(content)
  end)
  if not ok or type(data) ~= 'table' then
    return { recent = {} }
  end
  data.recent = data.recent or {}
  return data
end

local function save(data)
  local path = file()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local fd = io.open(path, 'w')
  if not fd then
    return
  end
  fd:write(vim.json.encode(data))
  fd:close()
end

--- Stable key for a ref ("psID-pID").
function M.ref_key(ref)
  return tostring(ref.psID) .. '-' .. tostring(ref.pID)
end

--- Remember that a problem was opened/pulled; most recent first.
function M.record(ref, title, dir)
  local data = M.load()
  local key = M.ref_key(ref)
  local recent = { { key = key, ref = ref, title = title, dir = dir, at = os.time() } }
  for _, entry in ipairs(data.recent) do
    if entry.key ~= key then
      recent[#recent + 1] = entry
    end
  end
  while #recent > MAX_RECENT do
    table.remove(recent)
  end
  data.recent = recent
  save(data)
end

function M.recent(limit)
  local data = M.load()
  local out = {}
  for i, entry in ipairs(data.recent) do
    if limit and i > limit then
      break
    end
    out[#out + 1] = entry
  end
  return out
end

--- Short verdict line shown on the dashboard ("AC 答案正确").
function M.set_last_verdict(submission_id, short, name)
  local data = M.load()
  data.last_verdict = { sid = submission_id, short = short, name = name, at = os.time() }
  save(data)
end

function M.last_verdict()
  return M.load().last_verdict
end

return M
