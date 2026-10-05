--- Submit the current solution (or run it against custom test data) and
--- follow the verdict in a floating window.
local api = require('pintia.api')
local config = require('pintia.config')
local float = require('pintia.ui.float')
local history = require('pintia.history')
local workspace = require('pintia.workspace')

local M = {}

local function buffer_content(path)
  -- Prefer the live buffer (unsaved edits included), fall back to disk.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= '' and vim.fn.fnamemodify(name, ':p') == vim.fn.fnamemodify(path, ':p') then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return table.concat(lines, '\n') .. '\n'
    end
  end
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local content = fd:read('*a')
  fd:close()
  return content
end

--- Poll a submission until the verdict is final.
--- progress(result) fires on every change; cb(err, result) ends it.
function M.poll(submissionID, custom, progress, cb)
  local deadline = os.time() + config.get().judge_timeout
  local last_status = nil

  local function tick()
    api.result(submissionID, custom, function(err, data)
      if err then
        cb(err)
        return
      end
      local status = api.status_of(data)
      if status ~= last_status then
        last_status = status
        if progress then
          progress(data)
        end
      end
      if not api.is_pending(data) then
        cb(nil, data)
        return
      end
      if os.time() > deadline then
        cb({ message = '等待判题超时（提交 ' .. tostring(submissionID) .. ' 仍在 ' .. (status or '?') .. '）' }, data)
        return
      end
      vim.defer_fn(tick, config.get().poll_interval)
    end)
  end

  tick()
end

--- Submit `path` for the problem described in the workspace's meta.json.
--- opts: { file_path, language?, custom_input? } — custom_input makes it a
--- server-side test run instead of a real submission.
function M.submit(opts, progress, cb)
  local ws = workspace.find(opts.file_path)
  if not ws then
    cb({ message = '未找到工作区（meta.json）：先用 :PintiaPull 拉题' })
    return
  end

  local file = opts.file_path or workspace.find_source(ws.dir)
  if not file then
    cb({ message = '工作区内没有源码文件' })
    return
  end

  local language = opts.language or api.language_of(file, vim.bo.filetype) or config.get().default_language
  local compiler = api.compiler_of(language)
  if not compiler then
    cb({ message = '无法判断语言（' .. tostring(language) .. '），请检查扩展名或 :PintiaSetup' })
    return
  end

  local source = buffer_content(file)
  if not source then
    cb({ message = '读取源码失败：' .. file })
    return
  end

  api.ensure_exam(ws.meta.psID, function(err, exam)
    if err then
      cb(err)
      return
    end
    if not exam or not exam.id then
      cb({ message = '无法获取/创建题集的 exam' })
      return
    end

    local detail_field = (ws.meta.type == 'CODE_COMPLETION') and 'codeCompletionSubmissionDetail' or 'programmingSubmissionDetail'
    local detail = {
      problemId = '0',
      problemSetProblemId = ws.meta.pID,
    }
    detail[detail_field] = { compiler = compiler, program = source }
    local custom = opts.custom_input ~= nil
    if custom then
      detail.customTestData = { hasCustomTestData = true, content = opts.custom_input }
    end

    api.submit(exam.id, { problemType = ws.meta.type or 'PROGRAMMING', details = { detail } }, function(serr, submission)
      if serr then
        cb(serr)
        return
      end
      local sid = submission and submission.submissionId
      if not sid then
        cb({ message = '提交响应缺少 submissionId：' .. vim.inspect(submission) })
        return
      end
      M.poll(sid, custom, progress, function(perr, result)
        cb(perr, vim.tbl_extend('force', result or {}, { submissionId = sid }))
      end)
    end)
  end)
end

--- Pretty-print a submission result: status, compile log, per-case results.
function M.format_result(result)
  local lines = {}
  local status = api.status_of(result)
  lines[#lines + 1] = string.format('状态: %s %s%s',
    api.verdict_short(status), api.verdict_name(status),
    (result.submission and result.submission.score) and (' · 得分 ' .. tostring(result.submission.score)) or '')

  local jr = api.judge_content(result)
  if jr then
    local comp = jr.compilationResult
    if comp then
      lines[#lines + 1] = comp.success and '编译通过' or '编译失败:'
      local log = vim.trim((comp.log or '') .. (comp.error or ''))
      if log ~= '' then
        for _, line in ipairs(vim.split(log, '\n', { plain = true })) do
          lines[#lines + 1] = '  ' .. line
        end
      end
    end
    local cases = {}
    for key, _ in pairs(jr.testcaseJudgeResults or {}) do
      cases[#cases + 1] = key
    end
    table.sort(cases)
    for _, key in ipairs(cases) do
      local tc = jr.testcaseJudgeResults[key]
      lines[#lines + 1] = string.format('  用例 %s  %s  %s ms  %s KB', key, tostring(tc.result), tostring(tc.time), tostring(tc.memory))
      if tc.result ~= 'ACCEPTED' then
        local out = vim.trim((tc.stdout or '') .. (tc.stderr or ''))
        if out ~= '' then
          lines[#lines + 1] = '    输出: ' .. out:sub(1, 160):gsub('\n', ' | ')
        end
      end
    end
  end
  return lines
end

local function is_auth_error(err)
  return err ~= nil and (err.code == 401 or (err.message or ''):find('401') ~= nil)
end

--- High level command body: float window with progress, judge detail at the end.
--- mode = 'submit' | 'test'; test_input is required for 'test'.
function M.run(file_path, mode, test_input, retried)
  local file = file_path
  if file == nil or file == '' then
    local ws = workspace.find(vim.api.nvim_buf_get_name(0))
    if ws then
      file = workspace.find_source(ws.dir)
    end
    file = file or vim.api.nvim_buf_get_name(0)
  end
  if file == '' or vim.fn.filereadable(file) == 0 then
    vim.notify('pintia: 当前 buffer 不是文件，或工作区里没有源码', vim.log.levels.WARN)
    return
  end

  local ws = workspace.find(file)
  local title = ws and ws.meta.title or vim.fn.fnamemodify(file, ':t')
  local short = vim.fn.fnamemodify(file, ':t')

  -- Persist pending edits before submitting; the write is in-place.
  local saved = workspace.save_modified(ws and ws.dir or nil, file)

  local verb = mode == 'test' and '测试' or '提交'
  local win = float.open({
    title = verb .. ' · ' .. short,
    width = 84,
    height = 16,
    lines = { verb .. ' ' .. short .. ' → ' .. title, '', '  等待评测机…' },
    follow = true,
  })

  local log = { verb .. ' ' .. short .. ' → ' .. title }
  if #saved > 0 then
    log[#log + 1] = '已保存到磁盘'
  end
  log[#log + 1] = ''

  M.submit({ file_path = file, custom_input = mode == 'test' and (test_input or '') or nil }, function(poll_data)
    local status = api.status_of(poll_data)
    log[#log] = string.format('  %s %s', api.verdict_short(status), api.verdict_name(status))
    win.set(log)
  end, function(err, result)
    if is_auth_error(err) and not retried then
      log[#log] = '  需要登录…(:PintiaLogin)'
      win.set(log)
      return
    end
    if err and not result then
      log[#log] = '  ✗ ' .. (err.message or err.error or '失败')
      win.set(log)
      vim.notify('pintia: ' .. (err.message or '失败'), vim.log.levels.ERROR)
      return
    end
    if err then
      log[#log] = '  ✗ ' .. (err.message or err.error or '失败')
      win.set(log)
    end
    if not result then
      return
    end

    local status = api.status_of(result)
    history.set_last_verdict(result.submissionId, api.verdict_short(status), api.verdict_name(status))
    for _, line in ipairs(M.format_result(result)) do
      log[#log + 1] = line
    end
    win.set(log)
    vim.notify(string.format('pintia: %s %s %s', verb, api.verdict_short(status), api.verdict_name(status)),
      status == 'ACCEPTED' and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end

return M
