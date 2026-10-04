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
      source = result.dir .. '/main.cpp'
      local fd = io.open(source, 'w')
      if fd then
        fd:write('#include <iostream>\nusing namespace std;\n\nint main() {\n    return 0;\n}\n')
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
  local function fetch(page, cb)
    api.problem_list(psID, page - 1, 200, function(err, items)
      if err then
        vim.notify('pintia: ' .. (err.message or err.error), vim.log.levels.ERROR)
        return
      end
      local out = {}
      for _, row in ipairs(items or {}) do
        local mark = row.problemStatus == 'ACCEPTED' and '✓' or ' '
        out[#out + 1] = {
          label = string.format('%s %-6s %s  %d分', mark, row.label or '?', vim.trim(row.title or ''), row.score or 0),
          data = { psID = psID, pID = row.id, label = row.label, psName = psName },
        }
      end
      -- one page is enough for the bundled picker unless the set is huge
      cb(out, 1)
    end)
  end
  fetch(1, function(items)
    picker.select({
      title = (psName or psID) .. ' · 题目',
      hint = '输入模糊过滤 · <CR> 拉取工作区 · <C-o> 只看题面',
      items = items,
      width = 96,
      height = 24,
      fetch_page = nil,
      on_select = function(item)
        pull_and_open(item.data.psID, item.data.pID, item.data.psName)
      end,
      secondary_key = '<C-o>',
      on_secondary = function(item)
        open_problem(item.data.psID, item.data.pID, item.data.psName)
      end,
      secondary_label = '<C-o> 只看题面',
    })
  end)
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

--- Run the current file against a sample (default 1st) or custom input on the
--- server, exactly like vscode-pintia's "Test".
function M.test(input_path)
  local ws = workspace.find(vim.api.nvim_buf_get_name(0)) or workspace.find(vim.fn.getcwd())
  if not ws then
    vim.notify('pintia: 当前目录不在题目工作区（先 :PintiaPull）', vim.log.levels.WARN)
    return
  end

  local test_input
  if input_path and input_path ~= '' then
    local fd = io.open(input_path, 'r')
    test_input = fd and fd:read('*a') or nil
    if fd then fd:close() end
    if not test_input then
      vim.notify('pintia: 读不到输入文件 ' .. input_path, vim.log.levels.ERROR)
      return
    end
  else
    local samples = workspace.read_samples(ws.dir)
    if #samples == 0 then
      vim.notify('pintia: 工作区没有 samples/，传一个输入文件：:PintiaTest path/to/input', vim.log.levels.WARN)
      return
    end
    test_input = samples[1].input
  end

  submit.run(nil, 'test', test_input and (test_input:match('\n$') and test_input or (test_input .. '\n')) or '')
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
