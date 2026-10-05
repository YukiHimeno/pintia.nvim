--- pintia.nvim: 拼题A (pintia.cn) inside Neovim.
---
--- 题面进 buffer、提交/自定义测试进浮动窗、判题进度实时跟进，全部走站点
--- 自身的 JSON API（与网页前端同一套接口），会话保存在本地文件里。
local api = require('pintia.api')
local config = require('pintia.config')
local float = require('pintia.ui.float')
local history = require('pintia.history')
local picker = require('pintia.ui.picker')
local statement = require('pintia.statement')
local submit = require('pintia.submit')
local workspace = require('pintia.workspace')

local M = {}

function M.setup(opts)
  local before = config.get().command_prefix
  config.setup(opts)
  if config.get().command_prefix ~= before then
    M.register_commands()
  end
  return config.get()
end

-- ---------------------------------------------------------------------------
-- commands: registered under a user-pickable prefix ('Pintia' or 'PTA').
-- ---------------------------------------------------------------------------

local COMMAND_SPECS = {
  { suffix = '', desc = 'pintia: 打开操作面板' },
  { suffix = 'Setup', desc = 'pintia: 交互式设置（工作区目录等）' },
  { suffix = 'Login', desc = 'pintia: 登录（PTASession cookie）' },
  { suffix = 'Logout', desc = 'pintia: 退出登录' },
  { suffix = 'Status', desc = 'pintia: 账号与工作区状态' },
  { suffix = 'ProblemSets', desc = 'pintia: 题集选择器' },
  { suffix = 'Problems', desc = 'pintia: 指定题集的题目列表', nargs = '*' },
  { suffix = 'Test', desc = 'pintia: 服务端测试（自定义输入）', nargs = '*' },
  { suffix = 'Submit', desc = 'pintia: 提交当前文件', nargs = '*' },
  { suffix = 'Watch', desc = 'pintia: 监视判题结果', nargs = '*' },
  { suffix = 'Health', desc = 'pintia: 环境自检' },
}

local function dispatch(suffix)
  return function(args)
    if suffix == '' then
      M.dashboard()
    elseif suffix == 'Setup' then
      M.settings()
    elseif suffix == 'Login' then
      M.login()
    elseif suffix == 'Logout' then
      M.logout()
    elseif suffix == 'Status' then
      M.status()
    elseif suffix == 'ProblemSets' then
      M.problem_sets()
    elseif suffix == 'Problems' then
      M.problems(args.fargs[1], args.fargs[2])
    elseif suffix == 'Test' then
      M.test(args.fargs[1])
    elseif suffix == 'Submit' then
      M.submit_cmd(args.fargs[1])
    elseif suffix == 'Watch' then
      M.watch(args.fargs[1])
    elseif suffix == 'Health' then
      M.health()
    end
  end
end

--- (Re)create the :<Prefix>* commands, dropping any from the previous prefix.
function M.register_commands()
  if M._command_names then
    for _, name in ipairs(M._command_names) do
      pcall(vim.api.nvim_del_user_command, name)
    end
  end
  M._command_names = {}
  local prefix = config.get().command_prefix or 'Pintia'
  for _, spec in ipairs(COMMAND_SPECS) do
    local name = prefix .. spec.suffix
    vim.api.nvim_create_user_command(name, dispatch(spec.suffix), { desc = spec.desc, nargs = spec.nargs or 0 })
    M._command_names[#M._command_names + 1] = name
  end
end

-- ---------------------------------------------------------------------------
-- refs
-- ---------------------------------------------------------------------------

local function ref_of_workspace()
  local ws = workspace.find(vim.api.nvim_buf_get_name(0)) or workspace.find(vim.fn.getcwd())
  if not ws then
    return nil
  end
  return { psID = ws.meta.psID, pID = ws.meta.pID, label = ws.meta.label, title = ws.meta.title, psName = ws.meta.psName }
end

-- ---------------------------------------------------------------------------
-- session
-- ---------------------------------------------------------------------------

function M.login()
  vim.ui.select({
    '微信扫码登录',
    '账号密码登录',
    'PTASession cookie 登录',
  }, { prompt = '选择登录方式:' }, function(choice)
    if choice == '微信扫码登录' then
      M.login_wechat()
    elseif choice == '账号密码登录' then
      M.login_password()
    elseif choice == 'PTASession cookie 登录' then
      M.login_cookie()
    end
  end)
end

function M.login_password()
  vim.ui.input({ prompt = '拼题A 账号（邮箱或手机号）: ' }, function(account)
    if account == nil or vim.trim(account) == '' then
      return
    end
    local password = vim.fn.inputsecret('密码: ')
    if password == '' then
      return
    end
    vim.notify('pintia: 登录中…', vim.log.levels.INFO)
    api.login_password(vim.trim(account), password, function(err, user, cookie)
      if err then
        vim.notify('pintia 登录失败: ' .. (err.message or err.error), vim.log.levels.ERROR)
        return
      end
      api.save_session({ cookie = cookie, id = user and user.id, nickname = user and (user.nickname or user.email) })
      vim.notify(string.format('pintia 已登录：%s', (user and (user.nickname or user.email)) or '账号'), vim.log.levels.INFO)
    end)
  end)
end

function M.login_wechat()
  api.wechat_auth_url(function(err, auth)
    if err or not auth or not auth.url then
      vim.notify('pintia 获取微信登录链接失败: ' .. (err and (err.message or err.error) or ''), vim.log.levels.ERROR)
      return
    end
    -- 终端里直接显示二维码（装了 qrencode 时），否则提示用户在浏览器打开
    local qr_lines = nil
    if vim.fn.executable('qrencode') == 1 then
      local out = vim.fn.system({ 'qrencode', '-t', 'UTF8', '-m', '1', auth.url })
      if vim.v.shell_error == 0 then
        qr_lines = vim.split(out:gsub('\n$', ''), '\n', { plain = true })
      end
    end
    if qr_lines then
      float.open({ title = '微信扫码登录 · q 关闭', lines = qr_lines, width = 72, height = math.min(#qr_lines + 2, 30), wrap = false })
    else
      vim.notify('pintia: 请用微信扫码打开此链接登录:\n' .. auth.url, vim.log.levels.INFO)
    end

    local deadline = os.time() + 120
    local function tick()
      api.wechat_state(auth.state, function(serr, state)
        if serr then
          vim.notify('pintia 查询微信登录状态失败: ' .. (serr.message or serr.error), vim.log.levels.WARN)
          return
        end
        local status = state and state.status
        if status == 'SUCCESSFUL' then
          api.wechat_user(auth.state, function(uerr, user)
            if uerr or not user or not user.id then
              vim.notify('pintia 获取微信用户失败', vim.log.levels.ERROR)
              return
            end
            api.wechat_login_users(auth.state, user.id, function(lerr, info, cookie)
              if lerr then
                vim.notify('pintia 微信登录失败: ' .. (lerr.message or lerr.error), vim.log.levels.ERROR)
                return
              end
              api.save_session({ cookie = cookie, id = info and info.id, nickname = info and (info.nickname or info.email), loginMethod = 'WeChat' })
              vim.notify(string.format('pintia 已登录：%s（微信扫码）', (info and (info.nickname or info.email)) or user.nickname or user.id), vim.log.levels.INFO)
            end)
          end)
          return
        end
        if status == 'FAILURE' then
          vim.notify('pintia 微信登录失败或已过期，请重试', vim.log.levels.ERROR)
          return
        end
        if os.time() > deadline then
          vim.notify('pintia 微信登录超时', vim.log.levels.WARN)
          return
        end
        vim.defer_fn(tick, 2000)
      end)
    end
    vim.defer_fn(tick, 2000)
  end)
end

function M.login_cookie()
  vim.ui.input({ prompt = 'PTASession cookie（https://pintia.cn 登录后浏览器取到）: ' }, function(cookie)
    if cookie == nil or vim.trim(cookie) == '' then
      return
    end
    cookie = vim.trim(cookie)
    if not cookie:match('^PTASession=') then
      cookie = 'PTASession=' .. cookie
    end
    if not cookie:match(';%s*$') then
      cookie = cookie .. ';'
    end
    api.save_session({ cookie = cookie })
    api.current_user(function(err, user)
      if err or not user then
        api.clear_session()
        vim.notify('pintia 登录失败: cookie 无效或已过期', vim.log.levels.ERROR)
        return
      end
      api.save_session({ cookie = cookie, id = user.id, nickname = user.nickname })
      vim.notify(string.format('pintia 已登录：%s', user.nickname or user.email or user.id), vim.log.levels.INFO)
    end)
  end)
end

function M.logout()
  api.sign_out(function()
    vim.notify('pintia 已退出登录', vim.log.levels.INFO)
  end)
end

function M.status()
  local lines = {}
  local session = api.load_session()
  local me, err = api.request_sync({ path = api.passport_url .. '/api/u/current' })
  if not session or err then
    lines[#lines + 1] = '账号: 未登录（:PintiaLogin）'
  else
    local user = me and me.user
    lines[#lines + 1] = string.format('账号: %s（%s）', session.nickname or (user and user.nickname) or '?', session.id or (user and user.id) or '')
  end
  lines[#lines + 1] = '工作区根目录: ' .. config.get().workdir
  local ws = workspace.find(vim.api.nvim_buf_get_name(0)) or workspace.find(vim.fn.getcwd())
  if ws then
    lines[#lines + 1] = string.format('当前工作区: %s', ws.dir)
    lines[#lines + 1] = string.format('题目: %s %s', ws.meta.label or '', ws.meta.title or '')
    local samples = workspace.read_samples(ws.dir)
    lines[#lines + 1] = string.format('样例 %d 组', #samples)
    local source = workspace.find_source(ws.dir)
    lines[#lines + 1] = '源码: ' .. (source or '（无）')
  else
    lines[#lines + 1] = '当前目录不在任何题目工作区内'
  end
  float.open({ title = 'pintia 状态', lines = lines, width = 72, height = #lines + 2 })
end

-- ---------------------------------------------------------------------------
-- browse & open
-- ---------------------------------------------------------------------------

local function open_problem(psID, pID, psName)
  api.problem(psID, pID, function(err, problem)
    if err then
      vim.notify('pintia: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    local markdown = statement.render(problem, { psName = psName, url = workspace.url_for(problem) })
    statement.open(tostring(psID) .. '-' .. tostring(pID), problem.title, markdown)
    history.record({ psID = psID, pID = pID, label = problem.label }, vim.trim(problem.title or ''), workspace.dir_for(psName or psID, problem))
    vim.notify(string.format('pintia: %s %s（:PintiaPull 拉取工作区）', problem.label or '', vim.trim(problem.title or '')), vim.log.levels.INFO)
  end)
end

--- Pull into the workspace and open the working files.
local function pull_and_open(psID, pID, psName)
  workspace.pull(psID, pID, psName, function(err, result)
    if err then
      vim.notify('pintia 拉取失败: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format('pintia: 已拉取 %s → %s', result.meta.title, result.dir), vim.log.levels.INFO)
    history.record({ psID = psID, pID = pID, label = result.meta.label }, result.meta.title, result.dir)

    statement.open(vim.fn.fnamemodify(result.dir, ':t'), result.meta.title, result.markdown)
    local source = workspace.find_source(result.dir)
    if not source then
      local ext_map = { GCC = 'c', CLANG = 'c', GXX = 'cpp', CLANGXX = 'cpp', JAVAC = 'java', PYTHON3 = 'py', GO = 'go' }
      local ext = ext_map[result.meta.compiler] or 'cpp'
      source = result.dir .. '/main.' .. ext
      local fd = io.open(source, 'w')
      if fd then
        if result.meta.type == 'CODE_COMPLETION' then
          fd:write('// 函数题：只写下面要求的函数即可，不要写 main。\n// 本地测试时会自动嵌入裁判测试程序样例。\n')
        elseif ext == 'c' then
          fd:write('#include <stdio.h>\n\nint main() {\n    return 0;\n}\n')
        else
          fd:write('#include <iostream>\nusing namespace std;\n\nint main() {\n    return 0;\n}\n')
        end
        fd:close()
      end
    end
    vim.cmd('tcd ' .. vim.fn.fnameescape(result.dir))
    if vim.fn.filereadable(source) == 1 then
      vim.cmd('split ' .. vim.fn.fnameescape(source))
    end
  end)
end

--- Open (pulling if needed) the workspace for saved refs.
function M.open_workspace(ref)
  if ref == nil then
    return
  end
  local ws = workspace.find(vim.fn.getcwd())
  if ws and ws.meta.pID == ref.pID and ws.meta.psID == ref.psID then
    statement.open(vim.fn.fnamemodify(ws.dir, ':t'), ws.meta.title, (function()
      local fd = io.open(ws.dir .. '/statement.md', 'r')
      local content = fd and fd:read('*a') or ''
      if fd then fd:close() end
      return content
    end)())
    return
  end
  pull_and_open(ref.psID, ref.pID, ref.psName)
end

function M.problems(psID, psName)
  if not psID or psID == '' then
    -- no argument: pick a problem set first, like :PintiaProblemSets
    M.problem_sets()
    return
  end
  -- Fetch both programming and code-completion problems, then show them
  -- together (the set may also have other types, ignored for coding work).
  local types = { 'PROGRAMMING', 'CODE_COMPLETION' }
  local results = {}
  local done = 0
  local function finalize()
    done = done + 1
    if done < #types then
      return
    end
    local items = {}
    for _, problem_type in ipairs(types) do
      for _, row in ipairs(results[problem_type] or {}) do
        local mark = row.problemStatus == 'ACCEPTED' and '✓' or ' '
        local tag = problem_type == 'CODE_COMPLETION' and '函数题' or '编程题'
        items[#items + 1] = {
          label = string.format('%s [%s] %-6s %s  %d分', mark, tag, row.label or '?', vim.trim(row.title or ''), row.score or 0),
          data = { psID = psID, pID = row.id, label = row.label, psName = psName },
        }
      end
    end
    picker.select({
      title = (psName or psID) .. ' · 题目',
      hint = '输入模糊过滤 · <CR> 拉取工作区 · <C-o> 只看题面',
      items = items,
      width = 96,
      height = 24,
      on_select = function(item)
        pull_and_open(item.data.psID, item.data.pID, item.data.psName)
      end,
      secondary_key = '<C-o>',
      on_secondary = function(item)
        open_problem(item.data.psID, item.data.pID, item.data.psName)
      end,
      secondary_label = '<C-o> 只看题面',
    })
  end
  for _, problem_type in ipairs(types) do
    api.problem_list(psID, 0, 200, function(err, rows)
      if not err and rows then
        results[problem_type] = rows
      else
        results[problem_type] = {}
      end
      finalize()
    end, problem_type)
  end
end

function M.problem_sets()
  api.problem_sets(function(err, sets)
    if err then
      vim.notify('pintia: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    local items = {}
    for _, ps in ipairs(sets or {}) do
      items[#items + 1] = {
        label = string.format('%s  %s', ps.id, vim.trim(ps.name or '')),
        data = { psID = ps.id, psName = ps.name },
      }
    end
    picker.select({
      title = 'Pintia 题集',
      hint = '回车查看题目',
      items = items,
      width = 96,
      height = 24,
      on_select = function(item)
        M.problems(item.data.psID, item.data.psName)
      end,
    })
  end)
end

-- ---------------------------------------------------------------------------
-- test & submit
-- ---------------------------------------------------------------------------

--- Compose a complete program for a function (CODE_COMPLETION) problem:
--- the judge driver with the user's code embedded.
local function build_completion_source(driver, user_code)
  local markers = { '你的代码将被嵌在这里', '你的代码', 'YOUR CODE' }
  for _, m in ipairs(markers) do
    local s, e = driver:find(m, 1, true)
    if s then
      -- replace the whole comment block containing the marker
      local cs = 1
      local pos = 1
      while true do
        local p = driver:find('/*', pos, true)
        if not p or p >= s then
          break
        end
        cs = p
        pos = p + 2
      end
      local ce = driver:find('*/', e, true)
      if ce then
        return driver:sub(1, cs - 1) .. user_code .. driver:sub(ce + 2)
      end
      return driver:sub(1, s - 1) .. user_code .. driver:sub(e + #m)
    end
  end
  -- no marker: insert the user's code just before main
  local main_pos = driver:find('int main', 1, true) or driver:find('public static void main', 1, true)
  if main_pos then
    return driver:sub(1, main_pos - 1) .. user_code .. '\n\n' .. driver:sub(main_pos)
  end
  return driver .. '\n' .. user_code
end

local function compiler_ext(compiler)
  local map = { GCC = 'c', CLANG = 'c', GXX = 'cpp', CLANGXX = 'cpp', JAVAC = 'java',
    PYTHON3 = 'py', PYTHON2 = 'py', GO = 'go', NODE = 'js', RUST = 'rs', KOTLIN = 'kt' }
  return map[compiler] or 'cpp'
end

--- Local test: run the current file against the workspace samples with a
--- local compiler/interpreter (samples are pulled with :PintiaProblemSets /
--- workspace pull). Function problems are tested through their judge driver.
function M.test()
  local ws = workspace.find(vim.api.nvim_buf_get_name(0)) or workspace.find(vim.fn.getcwd())
  if not ws then
    vim.notify('pintia: 当前目录不在题目工作区（先 :PintiaProblemSets 拉题）', vim.log.levels.WARN)
    return
  end

  local file = workspace.find_source(ws.dir)
  if not file then
    vim.notify('pintia: 工作区内没有源码文件', vim.log.levels.WARN)
    return
  end

  local samples = workspace.read_samples(ws.dir)
  if #samples == 0 then
    vim.notify('pintia: 工作区没有 samples/（重新拉题会带上样例）', vim.log.levels.WARN)
    return
  end

  -- The runner compiles the file from disk, so unsaved edits must land first.
  local saved = workspace.save_modified(ws.dir, file)

  local build_dir = ws.dir .. '/.pintia-build'
  vim.fn.mkdir(build_dir, 'p')

  local target = file
  local note = ''
  if ws.meta.type == 'CODE_COMPLETION' then
    if not ws.meta.driver then
      vim.notify('pintia: 题目缺少裁判测试程序样例，无法本地测试（可对照网页做）', vim.log.levels.ERROR)
      return
    end
    local fd = io.open(file, 'r')
    local source = fd and fd:read('*a') or ''
    if fd then fd:close() end
    target = string.format('%s/completion.%s', build_dir, compiler_ext(ws.meta.compiler))
    local out = io.open(target, 'w')
    out:write(build_completion_source(ws.meta.driver, source))
    out:close()
    note = '（函数题：已把你的代码嵌入裁判测试程序）'
  end

  local runner = require('pintia.runner')
  local language = runner.language_of(target, vim.bo.filetype)
  if not language then
    local lab = (config.get().default_language or ''):lower()
    language = lab:find('c%+%+') and 'C++' or lab:find('python') and 'Python' or lab:find('java') and 'Java' or lab:find('php') and 'PHP' or lab:find('go') and 'Go' or lab:find('c') and 'C' or nil
  end

  local log = { string.format('本地测试 %s · %s %s', vim.fn.fnamemodify(file, ':t'), ws.meta.label or '', ws.meta.title or '') }
  if note ~= '' then
    log[#log + 1] = note
  end
  log[#log + 1] = string.format('样例 %d 组', #samples)
  if #saved > 0 then
    log[#log + 1] = '已保存 ' .. table.concat(vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ':t') end, saved), ' ')
  end
  log[#log + 1] = ''
  local win = float.open({ title = 'pintia 本地测试', lines = log, width = 88, height = 18 })

  runner.run({
    ws_dir = ws.dir,
    file_path = target,
    language = language,
    tests = samples,
    time_limit = math.max((tonumber(ws.meta.timeLimit) or 1000) / 1000, 1),
  }, {
    on_compile = function()
      log[#log + 1] = '  编译中…'
      win.set(log)
    end,
    on_result = function(_, entry)
      log[#log] = string.format('  %s %s  (%d ms)', entry.pass and '✓' or '✗', entry.name, entry.elapsed_ms)
      if entry.error then
        log[#log + 1] = '    ' .. entry.error
      elseif not entry.pass then
        log[#log + 1] = '    期望: ' .. tostring(entry.expected):sub(1, 160)
        log[#log + 1] = '    实际: ' .. tostring(entry.actual):sub(1, 160)
      end
      log[#log + 1] = ''
      win.set(log)
    end,
    on_done = function(results, compile_output)
      if compile_output then
        log[#log + 1] = '  编译失败：'
        for _, line in ipairs(vim.split(compile_output, '\n', { plain = true })) do
          log[#log + 1] = '    ' .. line
        end
        win.set(log)
        return
      end
      local passed = 0
      for _, entry in ipairs(results) do
        if entry.pass then
          passed = passed + 1
        end
      end
      log[#log + 1] = string.format('  %d/%d 通过', passed, #results)
      win.set(log)
      vim.notify(string.format('pintia: 本地测试 %d/%d 通过', passed, #results),
        passed == #results and vim.log.levels.INFO or vim.log.levels.WARN)
    end,
  })
end

function M.submit_cmd(file)
  submit.run(file, 'submit')
end

--- Follow an existing submission (default: the latest of the current problem).
function M.watch(submission_id)
  local function poll(sid, custom)
    local log = { '监视提交 ' .. tostring(sid), '' }
    local win = float.open({ title = 'pintia 判题', lines = log, width = 88, height = 16 })
    submit.poll(sid, custom, function(data)
      local status = api.status_of(data)
      log[#log] = string.format('  %s %s', api.verdict_short(status), api.verdict_name(status))
      win.set(log)
    end, function(err, result)
      if err and not result then
        log[#log + 1] = '  ✗ ' .. (err.message or err.error)
        win.set(log)
        return
      end
      if not result then
        return
      end
      local status = api.status_of(result)
      history.set_last_verdict(sid, api.verdict_short(status), api.verdict_name(status))
      for _, line in ipairs(submit.format_result(result)) do
        log[#log + 1] = line
      end
      win.set(log)
    end)
  end

  if submission_id and submission_id ~= '' then
    poll(submission_id, false)
    return
  end
  local ref = ref_of_workspace()
  if not ref then
    vim.notify('pintia: 用法 :PintiaWatch <submissionId>，或先进入题目工作区', vim.log.levels.WARN)
    return
  end
  api.last_submission(ref.psID, ref.pID, function(err, sub)
    if err or not sub or not sub.id then
      vim.notify('pintia: 没有找到最近提交', vim.log.levels.WARN)
      return
    end
    poll(sub.id, false)
  end)
end

-- ---------------------------------------------------------------------------
-- misc
-- ---------------------------------------------------------------------------

function M.settings()
  require('pintia.ui.settings').open()
end

function M.dashboard()
  require('pintia.ui.dashboard').open({
    login = M.login,
    logout = M.logout,
    problem_sets = M.problem_sets,
    test = M.test,
    submit = M.submit_cmd,
    watch = M.watch,
    status = M.status,
    health = M.health,
    settings = M.settings,
    open_workspace = M.open_workspace,
  })
end

function M.health()
  local lines = { 'pintia.nvim health', '' }
  lines[#lines + 1] = 'curl: ' .. (vim.fn.executable('curl') == 1 and 'ok' or '缺少（必需）')
  lines[#lines + 1] = 'session: ' .. (vim.fn.filereadable(config.get().session_file) == 1 and 'exists' or '未登录')
  for _, tool in ipairs({ 'g++', 'gcc', 'javac', 'python3', 'php', 'go' }) do
    lines[#lines + 1] = tool .. ': ' .. (vim.fn.executable(tool) == 1 and 'ok' or '未安装（本地编译用）')
  end
  float.open({ title = 'pintia health', lines = lines, width = 64, height = #lines + 2 })
end

return M
