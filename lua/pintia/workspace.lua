--- Workspaces: pulled problems on disk (statement.md, meta.json, samples/).
local config = require('pintia.config')
local api = require('pintia.api')

local M = {}

local function slug(title, max_len)
  local cleaned = vim.trim((title or ''):gsub('[/\\:*?"<>|`\']', ' '):gsub('%s+', ' '))
  if cleaned == '' then
    cleaned = 'untitled'
  end
  return vim.fn.strcharpart(cleaned, 0, max_len or 60)
end

local function example_tests(problem)
  local cfg = problem.problemConfig or {}
  local prog = cfg.programmingProblemConfig or cfg.codeCompletionProblemConfig or {}
  local out = {}
  for _, item in ipairs(prog.exampleTestDatas or {}) do
    out[#out + 1] = { name = item.name or ('样例 ' .. #out + 1), input = item.input or '', output = item.output or '' }
  end
  return out
end

--- Where a problem's workspace lives.
function M.dir_for(problem_set_name, problem)
  local root = config.get().workdir
  local set_dir = slug(problem_set_name or problem.problemSetId or 'pintia', 60)
  local label = problem.label and (problem.label .. '-') or ''
  return string.format('%s/%s/%s%s', root, set_dir, label, slug(problem.title))
end

--- Extract the judge driver （裁判测试程序样例） from a code-completion
--- problem's content: the code block right after that heading.
function M.extract_driver(problem)
  local content = problem and problem.content or ''
  local _, e = content:find('裁判测试程序样例')
  local start = e and (content:find('```', e) or 0) + 3 or 0
  if start > 3 then
    -- skip the language tag on the fence line
    local _, eol = content:find('\n', start)
    local block_end = content:find('```', eol and (eol + 1) or start)
    if eol and block_end then
      return vim.trim(content:sub(eol + 1, block_end - 1))
    end
  end
  -- fallback: any fenced block containing a main function
  for lang, code in content:gmatch('```[%w+#]*\n(.-)```') do
    if code:find('int main', 1, true) or code:find('public static void main', 1, true) then
      return vim.trim(code)
    end
  end
  return nil
end

--- meta.json content: everything submit/test/poll needs.
function M.meta_for(problem, problem_set_name, url)
  local cfg = problem.problemConfig or {}
  local prog = cfg.programmingProblemConfig or cfg.codeCompletionProblemConfig or {}
  return {
    version = 1,
    psID = problem.problemSetId,
    psName = problem_set_name or '',
    pID = problem.id,
    label = problem.label or '',
    title = vim.trim(problem.title or ''),
    type = problem.type or 'PROGRAMMING',
    score = problem.score,
    compiler = problem.compiler,
    timeLimit = prog.timeLimit,
    memoryLimit = prog.memoryLimit,
    driver = problem.type == 'CODE_COMPLETION' and M.extract_driver(problem) or nil,
    problemSetId = problem.problemSetId,
    url = url,
    pulledAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
end

function M.url_for(problem)
  return string.format('https://pintia.cn/problem-sets/%s/exam/problems/type/7?problemSetProblemId=%s', problem.problemSetId, problem.id)
end

function M.write(dir, markdown, meta, samples)
  vim.fn.mkdir(dir .. '/samples', 'p')

  local statement_path = dir .. '/statement.md'
  local out = io.open(statement_path, 'w')
  if not out then
    return false, 'cannot write ' .. statement_path
  end
  out:write(markdown)
  out:close()

  local meta_path = dir .. '/meta.json'
  out = io.open(meta_path, 'w')
  if not out then
    return false, 'cannot write ' .. meta_path
  end
  out:write(vim.json.encode(meta))
  out:close()

  for i, sample in ipairs(samples or {}) do
    local fin = io.open(string.format('%s/samples/%d.in', dir, i), 'w')
    if fin then
      fin:write(((sample.input or ''):gsub('\r\n', '\n')))
      fin:close()
    end
    local fout = io.open(string.format('%s/samples/%d.out', dir, i), 'w')
    if fout then
      fout:write(((sample.output or ''):gsub('\r\n', '\n')))
      fout:close()
    end
  end

  return true
end

--- Find meta.json walking up from `start` (a file or directory path).
function M.find(start)
  local dir = vim.fn.fnamemodify(start or vim.api.nvim_buf_get_name(0), ':p:h')
  if dir == '' then
    dir = vim.fn.getcwd()
  end
  local meta_path = vim.fs.find('meta.json', { upward = true, path = dir, type = 'file' })[1]
  if not meta_path then
    return nil
  end
  local ok, meta = pcall(function()
    local fd = io.open(meta_path, 'r')
    local content = fd:read('*a')
    fd:close()
    return vim.json.decode(content)
  end)
  if not ok or type(meta) ~= 'table' or meta.psID == nil or meta.pID == nil then
    return nil
  end
  return { dir = vim.fn.fnamemodify(meta_path, ':h'), meta = meta, meta_path = meta_path }
end

function M.read_samples(ws_dir)
  local samples = {}
  for i = 1, 99 do
    local in_path = string.format('%s/samples/%d.in', ws_dir, i)
    local out_path = string.format('%s/samples/%d.out', ws_dir, i)
    if vim.fn.filereadable(in_path) == 0 then
      break
    end
    local fin = io.open(in_path, 'r')
    local input = fin and fin:read('*a') or ''
    if fin then fin:close() end
    local fout = io.open(out_path, 'r')
    local output = fout and fout:read('*a') or ''
    if fout then fout:close() end
    samples[#samples + 1] = {
      input = (input:gsub('\r\n', '\n')),
      output = (output:gsub('\r\n', '\n')),
      name = string.format('样例 %d', i),
    }
  end
  return samples
end

--- Save modified buffers that belong to the workspace (plus an explicit extra
--- path) before an action reads files from disk. Runs in place: the window
--- layout, tab pages and focus are left exactly as they were, and autocmds are
--- skipped so a save hook can never rearrange the editor mid-action.
function M.save_modified(ws_dir, extra_path)
  local saved = {}
  local ws_root = ws_dir and (vim.fn.fnamemodify(ws_dir, ':p'):gsub('/+$', '')) or nil
  local ws_prefix = ws_root and (ws_root .. '/') or nil
  local target = extra_path and vim.fn.fnamemodify(extra_path, ':p') or nil

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].modified
      and vim.bo[bufnr].buftype == ''
      and not vim.bo[bufnr].readonly
    then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' then
        local path = vim.fn.fnamemodify(name, ':p')
        local relevant = (target ~= nil and path == target)
          or (ws_prefix ~= nil and vim.startswith(path, ws_prefix))
        if relevant then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd('silent noautocmd update')
          end)
          saved[#saved + 1] = path
        end
      end
    end
  end
  return saved
end

--- Pick the source file to build/submit: main.* first, else the only candidate.
function M.find_source(dir)
  local extensions = { 'cpp', 'cc', 'cxx', 'c', 'java', 'py', 'go', 'rs', 'js', 'kt' }
  local candidates = {}
  for _, ext in ipairs(extensions) do
    local found = vim.fn.glob(dir .. '/*.' .. ext, false, true)
    vim.list_extend(candidates, found)
  end
  if #candidates == 0 then
    return nil
  end
  for _, path in ipairs(candidates) do
    if vim.fn.fnamemodify(path, ':t'):match('^main%.') then
      return path
    end
  end
  return #candidates == 1 and candidates[1] or nil
end

--- Fetch + pull a problem into its workspace. cb(err, { dir, markdown, meta }).
function M.pull(psID, pID, psName, cb)
  local statement = require('pintia.statement')

  api.problem(psID, pID, function(err, problem)
    if err then
      cb(err)
      return
    end
    local url = M.url_for(problem)
    local markdown = statement.render(problem, { psName = psName, url = url })
    local meta = M.meta_for(problem, psName, url)
    local dir = M.dir_for(psName or problem.problemSetId, problem)
    local ok, werr = M.write(dir, markdown, meta, example_tests(problem))
    if not ok then
      cb({ message = werr })
      return
    end
    cb(nil, { dir = dir, markdown = markdown, meta = meta, problem = problem })
  end)
end

return M
