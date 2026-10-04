--- HTTP client for the Pintia (拼题A) JSON API.
---
--- Talks to https://pintia.cn through `curl`, with the login cookie stored in a
--- JSON file — the same `PTASession` cookie the web frontend uses. Every
--- request carries the cookie so the session survives restarts.
local config = require('pintia.config')

local M = {}

M.base_url = 'https://pintia.cn'
M.passport_url = 'https://passport.pintia.cn'

--- Submission statuses that mean "still judging".
local PENDING_STATUSES = { WAITING = true, JUDGING = true }

--- Human-readable verdicts for a judgeResponse status.
local VERDICTS = {
  OVERRIDDEN = { short = 'VR', name = '已被覆盖' },
  WAITING = { short = 'WT', name = '等待评测' },
  JUDGING = { short = 'JG', name = '正在评测' },
  COMPILE_ERROR = { short = 'CE', name = '编译错误' },
  ACCEPTED = { short = 'AC', name = '答案正确' },
  PARTIAL_ACCEPTED = { short = 'PA', name = '部分正确' },
  PRESENTATION_ERROR = { short = 'PE', name = '格式错误' },
  WRONG_ANSWER = { short = 'WA', name = '答案错误' },
  MULTIPLE_ERROR = { short = 'ME', name = '多种错误' },
  TIME_LIMIT_EXCEEDED = { short = 'TLE', name = '运行超时' },
  MEMORY_LIMIT_EXCEEDED = { short = 'MLE', name = '内存超限' },
  NON_ZERO_EXIT_CODE = { short = 'RE', name = '非零返回' },
  SEGMENTATION_FAULT = { short = 'SG', name = '段错误' },
  FLOAT_POINT_EXCEPTION = { short = 'FE', name = '浮点错误' },
  OUTPUT_LIMIT_EXCEEDED = { short = 'OLE', name = '输出超限' },
  INTERNAL_ERROR = { short = 'IE', name = '内部错误' },
  RUNTIME_ERROR = { short = 'RE', name = '运行时错误' },
}

function M.verdict_name(status)
  if status == nil or status == '' then
    return '未知'
  end
  local v = VERDICTS[status]
  return v and v.name or status
end

function M.verdict_short(status)
  if status == nil or status == '' then
    return '?'
  end
  local v = VERDICTS[status]
  return v and v.short or status:sub(1, 3)
end

--- A submission is done when the queue drained (queued == -1) and the judge
--- left WAITING/JUDGING — mirrors the VS Code extension's polling condition.
function M.is_pending(result)
  if result == nil then
    return true
  end
  if result.queued and result.queued >= 0 then
    return true
  end
  local status = result.submission and result.submission.status
  return status == nil or PENDING_STATUSES[status] == true
end

-- ---------------------------------------------------------------------------
-- session storage
-- ---------------------------------------------------------------------------

function M.load_session()
  local path = config.get().session_file
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, data = pcall(function()
    local fd = io.open(path, 'r')
    local content = fd:read('*a')
    fd:close()
    return vim.json.decode(content)
  end)
  if not ok or type(data) ~= 'table' or not data.cookie then
    return nil
  end
  return data
end

function M.save_session(session)
  local path = config.get().session_file
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local fd = io.open(path, 'w')
  if not fd then
    return false
  end
  fd:write(vim.json.encode(session))
  fd:close()
  return true
end

function M.clear_session()
  vim.fn.delete(config.get().session_file)
end

-- ---------------------------------------------------------------------------
-- low level
-- ---------------------------------------------------------------------------

local function curl_base()
  return { 'curl', '-sS', '--max-time', '60', '-H', 'Accept: application/json;charset=UTF-8', '-H', 'Content-Type: application/json;charset=UTF-8', '-H', 'Accept-Language: zh-CN' }
end

local function with_cookie(argv)
  local session = M.load_session()
  if session and session.cookie then
    vim.list_extend(argv, { '-H', 'Cookie: ' .. session.cookie })
  end
  return argv
end

--- JSON null decodes to vim.NIL, which is truthy in Lua and breaks string
--- concatenation, `and` chains and vim.json.encode. Convert it (recursively)
--- to real nil so callers never see it.
local function clean_nil(value)
  if value == vim.NIL then
    return nil
  end
  if type(value) == 'table' then
    for key, item in pairs(value) do
      value[key] = clean_nil(item)
    end
  end
  return value
end

--- Split "<body>\n<status>" (curl -w) into its parts.
local function split_status(stdout)
  local nl = stdout:match('.*()\n')
  if not nl then
    return stdout, nil
  end
  local body = stdout:sub(1, nl - 1)
  local status = tonumber(stdout:sub(nl + 1))
  return body, status
end

--- Pintia answers plain JSON (no envelope). err is { code, error, message }.
local function unwrap(body, status)
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= 'table' then
    if status and status >= 400 then
      return nil, { code = status, error = 'Http.' .. tostring(status), message = 'server returned HTTP ' .. status }
    end
    return nil, { code = -1, error = 'Api.InvalidResponse', message = 'unexpected (non-JSON) response' }
  end
  if status and status >= 400 then
    local msg = data.message or (type(data.error) == 'table' and data.error.message) or ('HTTP ' .. status)
    local code = type(data.error) == 'table' and (data.error.code or data.error.message) or nil
    return nil, { code = status, error = code or ('Http.' .. tostring(status)), message = msg }
  end
  if data.error and type(data.error) == 'table' and data.error.code then
    return nil, { code = data.error.code, error = data.error.code, message = data.error.message or 'request failed' }
  end
  return clean_nil(data), nil
end

local function build_url(path, query)
  local url = path:match('^https?://') and path or (M.base_url .. path)
  if query then
    local parts = {}
    for k, v in pairs(query) do
      if v ~= nil and v ~= '' then
        parts[#parts + 1] = k .. '=' .. vim.uri_encode(tostring(v))
      end
    end
    if #parts > 0 then
      url = url .. (url:find('?', 1, true) and '&' or '?') .. table.concat(parts, '&')
    end
  end
  return url
end

local function build_argv(opts)
  local args = { '-w', '\n%{http_code}' }
  if opts.method == 'POST' then
    args[#args + 1] = '-X'
    args[#args + 1] = 'POST'
  elseif opts.method == 'DELETE' then
    args[#args + 1] = '-X'
    args[#args + 1] = 'DELETE'
  end
  if opts.body then
    args[#args + 1] = '--data-raw'
    args[#args + 1] = vim.json.encode(opts.body)
  end
  if opts.headers_file then
    args[#args + 1] = '-D'
    args[#args + 1] = opts.headers_file
  end
  args[#args + 1] = build_url(opts.path, opts.query)
  local argv = curl_base()
  vim.list_extend(argv, args)
  if opts.no_cookie then
    return argv
  end
  return with_cookie(argv)
end

--- Async request capturing response headers; cb(err, data, headers_text).
function M.request_with_headers(opts, cb)
  local tmp = vim.fn.tempname()
  opts.headers_file = tmp
  vim.system(build_argv(opts), { text = true }, function(result)
    vim.schedule(function()
      local headers = {}
      local fd = io.open(tmp, 'r')
      if fd then
        headers = fd:read('*a') or ''
        fd:close()
      end
      os.remove(tmp)
      if result.code ~= 0 then
        cb({ code = result.code, error = 'Http.Curl', message = (result.stderr or ''):gsub('%s+$', '') }, nil)
        return
      end
      local body, status = split_status(result.stdout or '')
      local data, err = unwrap(body, status)
      cb(err, data, headers)
    end)
  end)
end

--- Find the PTASession cookie in a raw Set-Cookie header dump.
function M.ptasession_from_headers(headers)
  if not headers then
    return nil
  end
  for line in headers:gmatch('[^\r\n]+') do
    local sc = line:match('^[Ss]et%-[Cc]ookie:%s*(.+)$')
    if sc then
      for part in sc:gmatch('[^;]+') do
        local kv = vim.trim(part)
        if kv:match('^PTASession=') then
          return kv .. ';'
        end
      end
    end
  end
  return nil
end

--- Async request. cb(err, data). opts: { method, path, query, body }
function M.request(opts, cb)
  vim.system(build_argv(opts), { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb({ code = result.code, error = 'Http.Curl', message = (result.stderr or ''):gsub('%s+$', '') }, nil)
        return
      end
      local body, status = split_status(result.stdout or '')
      local data, err = unwrap(body, status)
      cb(err, data)
    end)
  end)
end

--- Synchronous request (blocking); returns (data, err).
function M.request_sync(opts)
  local result = vim.system(build_argv(opts), { text = true }):wait()
  if result.code ~= 0 then
    return nil, { code = result.code, error = 'Http.Curl', message = (result.stderr or ''):gsub('%s+$', '') }
  end
  local body, status = split_status(result.stdout or '')
  return unwrap(body, status)
end

-- ---------------------------------------------------------------------------
-- login flows
-- ---------------------------------------------------------------------------

--- Account/password login (pintia web 登录接口).
--- account may be an e-mail address or a phone number; cb(err, user, cookie).
function M.login_password(account, password, cb)
  local body = { password = password, rememberMe = true }
  if account:find('@', 1, true) then
    body.email = account
  else
    body.phone = account
  end
  M.request_with_headers({ method = 'POST', path = M.passport_url .. '/api/users/sessions', body = body, no_cookie = true }, function(err, data, headers)
    if err then
      if err.message == 'Wrong Captcha' or (err.error or ''):find('GATEWAY') then
        cb({ error = 'Captcha', message = '拼题A 登录接口要求极验验证码（Geetest），外部客户端无法绕过；请改用「微信扫码」或「Cookie」登录' })
        return
      end
      cb(err)
      return
    end
    local cookie = M.ptasession_from_headers(headers)
    if not cookie then
      cb({ error = 'Api.InvalidResponse', message = '响应中没有 PTASession cookie' })
      return
    end
    cb(nil, data and data.user, cookie)
  end)
end

--- WeChat QR login: step 1, fetch the authorize url + state.
function M.wechat_auth_url(cb)
  M.request({ path = M.passport_url .. '/api/oauth/wechat/official-account/auth-url', no_cookie = true }, cb)
end

--- WeChat QR login: step 2, poll state.
function M.wechat_state(state, cb)
  M.request({ path = M.passport_url .. '/api/oauth/wechat/official-account/state/' .. state, no_cookie = true }, cb)
end

--- WeChat QR login: step 3, fetch scanned user (needs exact casing path:
--- /api/oauth/wechat/state/{state}/user).
function M.wechat_user(state, cb)
  M.request({ path = M.passport_url .. '/api/oauth/wechat/state/' .. state .. '/user', no_cookie = true }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, data and data.user)
  end)
end

--- WeChat QR login: step 4, create the session; cb(err, user, cookie).
function M.wechat_login_users(state, userId, cb)
  M.request_with_headers({
    method = 'POST',
    path = M.passport_url .. '/api/users/sessions/state/' .. state .. '/login_users/' .. userId,
    no_cookie = true,
  }, function(err, data, headers)
    if err then
      cb(err)
      return
    end
    local cookie = M.ptasession_from_headers(headers)
    if not cookie then
      cb({ error = 'Api.InvalidResponse', message = '响应中没有 PTASession cookie' })
      return
    end
    cb(nil, data and data.user, cookie)
  end)
end

-- ---------------------------------------------------------------------------
-- endpoints
-- ---------------------------------------------------------------------------

function M.current_user(cb)
  M.request({ path = M.passport_url .. '/api/u/current' }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, data and data.user)
  end)
end

function M.sign_out(cb)
  M.request({ method = 'DELETE', path = '/api/u/info' }, function(err, data)
    M.clear_session()
    if cb then
      cb(err, data)
    end
  end)
end

--- All always-available problem sets (public catalogue).
function M.problem_sets(cb)
  M.request({ path = '/api/problem-sets/always-available' }, function(err, data)
    if err then
      cb(err)
      return
    end
    local sets = {}
    local seen = {}
    for _, item in ipairs((data and data.problemSets) or {}) do
      if not seen[item.id] then
        seen[item.id] = true
        sets[#sets + 1] = item
      end
    end
    cb(nil, sets)
  end)
end

--- Problem sets the logged-in user joined/created.
function M.my_problem_sets(cb)
  local filter = vim.json.encode({ endAtAfter = os.date('!%Y-%m-%dT%H:%M:%SZ') })
  M.request({ path = '/api/problem-sets', query = { filter = filter } }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, (data and data.problemSets) or {})
  end)
end

function M.problem_summaries(psID, cb)
  M.request({ path = '/api/problem-sets/' .. psID .. '/problem-summaries' }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, (data and data.summaries) or {})
  end)
end

--- Programming problems of a problem set, one page (0-based) of at most `limit`.
function M.problem_list(psID, page, limit, cb)
  M.request({
    path = '/api/problem-sets/' .. psID .. '/exam-problem-list',
    query = { problem_type = 'PROGRAMMING', page = page or 0, limit = limit or 200 },
  }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, (data and data.problemSetProblems) or {})
  end)
end

function M.problem(psID, pID, cb)
  M.request({ path = '/api/problem-sets/' .. psID .. '/exam-problems/' .. pID }, function(err, data)
    if err then
      cb(err)
      return
    end
    if data and data.problemSetProblem then
      data.problemSetProblem.organization = data.organization
      cb(nil, data.problemSetProblem)
    else
      cb({ error = 'Api.InvalidResponse', message = '题目详情缺失' })
    end
  end)
end

function M.exams(psID, cb)
  M.request({ path = '/api/problem-sets/' .. psID .. '/exams' }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, data)
  end)
end

function M.create_exam(psID, cb)
  M.request({ method = 'POST', path = '/api/problem-sets/' .. psID .. '/exams' }, cb)
end

--- Fetch the exam, creating one when missing (mirrors the web flow).
function M.ensure_exam(psID, cb)
  M.exams(psID, function(err, data)
    if err then
      cb(err)
      return
    end
    if data and data.exam and data.exam.id then
      cb(nil, data.exam)
      return
    end
    M.create_exam(psID, function(cerr)
      if cerr then
        cb(cerr)
        return
      end
      M.exams(psID, function(err2, data2)
        if err2 then
          cb(err2)
          return
        end
        cb(nil, data2 and data2.exam)
      end)
    end)
  end)
end

--- POST /api/exams/{examID}/submissions; body is an IProblemCode-shaped table.
function M.submit(examID, body, cb)
  M.request({ method = 'POST', path = '/api/exams/' .. examID .. '/submissions', body = body }, function(err, data)
    if err then
      cb(err)
      return
    end
    if data and data.error and data.error.message then
      cb({ error = data.error.code or 'Api.Error', message = data.error.message })
      return
    end
    cb(nil, data)
  end)
end

--- Poll a submission. custom = true uses the custom-test-data endpoint.
function M.result(submissionID, custom, cb)
  local suffix = custom and '?custom_test_data_submission=true' or ''
  M.request({ path = '/api/submissions/' .. submissionID .. suffix }, cb)
end

function M.last_submission(psID, pID, cb)
  M.request({
    path = '/api/problem-sets/' .. psID .. '/last-submissions',
    query = { problem_set_problem_id = pID },
  }, function(err, data)
    if err then
      cb(err)
      return
    end
    cb(nil, data and data.submission)
  end)
end

-- ---------------------------------------------------------------------------
-- compilers (mirror of vscode-pintia's langCompilerMapping)
-- ---------------------------------------------------------------------------

M.LANGUAGE_COMPILER = {
  ['C (gcc)'] = 'GCC',
  ['C++ (g++)'] = 'GXX',
  ['C (clang)'] = 'CLANG',
  ['C++ (clang++)'] = 'CLANGXX',
  ['Java (javac)'] = 'JAVAC',
  ['Python (python2)'] = 'PYTHON2',
  ['Python (python3)'] = 'PYTHON3',
  ['Ruby (ruby)'] = 'RUBY',
  ['Bash (bash)'] = 'BASH',
  ['CommonLisp (sbcl)'] = 'CLISP',
  ['Pascal (fpc)'] = 'FPC',
  ['Go (go)'] = 'GO',
  ['Haskell (ghc)'] = 'GHC',
  ['Lua (lua)'] = 'LUA',
  ['C# (dotnet)'] = 'MCS',
  ['JavaScript (node)'] = 'NODE',
  ['OCaml (ocamlc)'] = 'OCAMLC',
  ['PHP (php)'] = 'PHP',
  ['Perl (perl)'] = 'PERL',
  ['Kotlin (kotlinc)'] = 'KOTLIN',
  ['Rust (rustc)'] = 'RUST',
  ['SQL (SQL)'] = 'SQL',
}

local EXT_LANGUAGE = {
  c = 'C (gcc)', cpp = 'C++ (g++)', cc = 'C++ (g++)', cxx = 'C++ (g++)',
  java = 'Java (javac)', py = 'Python (python3)', rb = 'Ruby (ruby)',
  sh = 'Bash (bash)', go = 'Go (go)', lua = 'Lua (lua)', php = 'PHP (php)',
  pl = 'Perl (perl)', kt = 'Kotlin (kotlinc)', rs = 'Rust (rustc)',
  js = 'JavaScript (node)', sql = 'SQL (SQL)', hs = 'Haskell (ghc)',
  cs = 'C# (dotnet)', ml = 'OCaml (ocamlc)', pas = 'Pascal (fpc)',
}

local FT_LANGUAGE = {
  c = 'C (gcc)', cpp = 'C++ (g++)', java = 'Java (javac)', python = 'Python (python3)',
  ruby = 'Ruby (ruby)', sh = 'Bash (bash)', go = 'Go (go)', lua = 'Lua (lua)',
  php = 'PHP (php)', perl = 'Perl (perl)', kotlin = 'Kotlin (kotlinc)',
  rust = 'Rust (rustc)', javascript = 'JavaScript (node)', sql = 'SQL (SQL)',
}

--- Best-effort "language label" for a source file: extension first, then ft.
function M.language_of(path, filetype)
  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  if EXT_LANGUAGE[ext] then
    return EXT_LANGUAGE[ext]
  end
  if filetype and FT_LANGUAGE[filetype] then
    return FT_LANGUAGE[filetype]
  end
  return nil
end

function M.compiler_of(language_label)
  return M.LANGUAGE_COMPILER[language_label]
end

-- ---------------------------------------------------------------------------
-- formatting helpers shared by submit/watch/dashboard
-- ---------------------------------------------------------------------------

--- Extract the programming judge content (compilation + per-case results).
function M.judge_content(result)
  local submission = result and result.submission
  if not submission or not submission.judgeResponseContents then
    return nil
  end
  for _, content in ipairs(submission.judgeResponseContents) do
    if content.programmingJudgeResponseContent then
      return content.programmingJudgeResponseContent
    end
    if content.codeCompletionJudgeResponseContent then
      return content.codeCompletionJudgeResponseContent
    end
  end
  return nil
end

function M.status_of(result)
  if not result or not result.submission then
    return nil
  end
  return result.submission.status
end

return M
