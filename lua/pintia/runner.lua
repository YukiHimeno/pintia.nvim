--- Local runner: compile the solution and run it against samples / judge data.
local M = {}

local specs = {
  C = { compile = { 'gcc', '-O2', '-o', '{build}/program', '{file}' }, run = { '{build}/program' } },
  ['C++'] = { compile = { 'g++', '-O2', '-o', '{build}/program', '{file}' }, run = { '{build}/program' } },
  Java = { compile = { 'javac', '-encoding', 'UTF-8', '-d', '{build}', '{file}' }, run = { 'java', '-cp', '{build}', '{class}' } },
  Python = { run = { 'python3', '{file}' } },
  PHP = { run = { 'php', '{file}' } },
  Go = { run = { 'go', 'run', '{file}' } },
}

--- Map a file name / filetype to a judge language name.
function M.language_of(path, filetype)
  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  local by_ext = {
    c = 'C', cpp = 'C++', cc = 'C++', cxx = 'C++', java = 'Java',
    py = 'Python', php = 'PHP', go = 'Go',
  }
  if by_ext[ext] then
    return by_ext[ext]
  end
  local by_ft = {
    c = 'C', cpp = 'C++', java = 'Java', python = 'Python', php = 'PHP', go = 'Go',
  }
  return filetype and by_ft[filetype] or nil
end

local function expand(argv, ctx)
  local out = {}
  for _, part in ipairs(argv) do
    out[#out + 1] = (part:gsub('{(%w+)}', function(key)
      return ctx[key] or ''
    end))
  end
  return out
end

function M.spec_for(language, file, build_dir)
  local spec = specs[language]
  if not spec then
    return nil
  end
  local ctx = {
    file = file,
    build = build_dir,
    class = vim.fn.fnamemodify(file, ':t:r'),
  }
  return {
    compile = spec.compile and expand(spec.compile, ctx) or nil,
    run = expand(spec.run, ctx),
  }
end

local function normalize(text)
  text = (text or ''):gsub('\r\n', '\n')
  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = (line:gsub('%s+$', ''))
  end
  while #lines > 0 and lines[#lines] == '' do
    table.remove(lines)
  end
  return table.concat(lines, '\n')
end
M.normalize = normalize

local current = { handle = nil, cancelled = false }

function M.cancel()
  current.cancelled = true
  if current.handle then
    pcall(function() current.handle:kill(15) end)
  end
end

-- ---------------------------------------------------------------------------

--- Run every test case sequentially.
--- opts: { ws_dir, file_path (or content), language, tests, time_limit }
--- callbacks: on_start(n_total), on_result(index, result), on_done(results, compile_output)
function M.run(opts, callbacks)
  local build_dir = opts.ws_dir .. '/.pintia-build'
  vim.fn.mkdir(build_dir, 'p')

  local spec = M.spec_for(opts.language, opts.file_path, build_dir)
  if not spec then
    callbacks.on_done({}, 'unsupported language: ' .. tostring(opts.language))
    return
  end

  current.cancelled = false
  local results = {}

  local function finish(compile_output)
    current.handle = nil
    callbacks.on_done(results, compile_output)
  end

  local function run_tests()
    local timeout_ms = math.max((opts.time_limit or 1) * 1000 + 1000, 5000)
    local index = 0

    local function next_case()
      if current.cancelled then
        finish(nil)
        return
      end
      index = index + 1
      local test = opts.tests[index]
      if not test then
        finish(nil)
        return
      end

      local started = vim.uv.hrtime()
      local handle = vim.system(spec.run, { stdin = test.input or '', text = true, timeout = timeout_ms }, function(result)
        vim.schedule(function()
          local elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1e6)
          local entry = {
            index = index,
            name = test.name or ('#' .. index),
            pass = false,
            elapsed_ms = elapsed_ms,
          }
          if result.code ~= 0 then
            entry.error = string.format('exit %d%s', result.code, result.stderr ~= '' and (': ' .. vim.trim((result.stderr or ''):sub(1, 300))) or '')
          else
            local actual = normalize(result.stdout)
            local expected = normalize(test.output)
            entry.pass = actual == expected
            entry.actual = actual
            entry.expected = expected
          end
          results[#results + 1] = entry
          callbacks.on_result(index, entry)
          next_case()
        end)
      end)
      current.handle = handle
    end

    next_case()
  end

  if spec.compile then
    if callbacks.on_compile then
      callbacks.on_compile()
    end
    local handle = vim.system(spec.compile, { text = true, timeout = 60000 }, function(result)
      vim.schedule(function()
        if current.cancelled then
          finish(nil)
          return
        end
        if result.code ~= 0 then
          finish(vim.trim((result.stderr or '') .. (result.stdout or '')))
          return
        end
        run_tests()
      end)
    end)
    current.handle = handle
  else
    run_tests()
  end
end

return M
