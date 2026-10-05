--- Problem statements: HTML/markdown → markdown → buffer.
---
--- Pintia descriptions arrive as HTML (Word-era markup with KaTeX spans),
--- we convert to markdown (headings, lists, code, tables, images, links),
--- keeping a readable buffer that plays well with treesitter markdown and
--- render-markdown.nvim when the user has them.
local M = {}

local ENTITIES = {
  nbsp = ' ', lt = '<', gt = '>', amp = '&', quot = '"', apos = "'",
  ['#39'] = "'", ['#44'] = ',', ldquo = '“', rdquo = '”', hellip = '…', mdash = '—', ndash = '–',
  times = '×', le = '≤', ge = '≥', ne = '≠', middot = '·', minus = '−',
}

local function decode_entities(text)
  text = text:gsub('&#(%d+);', function(n)
    local code = tonumber(n)
    if code and code > 0 and code < 0x110000 then
      return vim.fn.nr2char(code)
    end
    return ''
  end)
  text = text:gsub('&#[xX](%x+);', function(n)
    return vim.fn.nr2char(tonumber(n, 16))
  end)
  text = text:gsub('&(%a+#?%d*);', function(name)
    return ENTITIES[name] or ('&' .. name .. ';')
  end)
  return text
end

local function absolutize(src)
  if src:sub(1, 5) == 'data:' then
    return nil
  end
  if src:match('^https?://') then
    return src
  end
  if src:sub(1, 1) == '/' then
    return 'https://pintia.cn' .. src
  end
  return 'https://pintia.cn/' .. src
end

--- KaTeX inline markup → $latex$ using the embedded TeX annotation.
local function katex_to_tex(html)
  return html:gsub('<span class="katex".-</span>%s*</span>', function(block)
    local tex = block:match('<annotation encoding="application/x%-tex">(.-)</annotation>')
    if tex then
      return '$' .. vim.trim(decode_entities(tex)) .. '$'
    end
    return ''
  end):gsub('<span class="katex.-</annotation></semantics></math></span>', function(block)
    local tex = block:match('<annotation encoding="application/x%-tex">(.-)</annotation>')
    return tex and ('$' .. vim.trim(decode_entities(tex)) .. '$') or ''
  end)
end

--- Convert a statement HTML fragment to markdown.
function M.html_to_markdown(html)
  if html == nil or html == '' then
    return ''
  end

  local text = html
  text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
  text = text:gsub('<script.->.-</script>', '')
  text = text:gsub('<style.->.-</style>', '')
  text = text:gsub('<xml.->.-</xml>', '')
  text = text:gsub('<w:[^>]->.-</w:[^>]->', '')
  text = katex_to_tex(text)

  -- code blocks first so their content is not touched by inline rules
  text = text:gsub('<pre[^>]*>(.-)</pre>', function(code)
    code = decode_entities(code):gsub('<br%s*/?>', '\n'):gsub('^%s*\n', ''):gsub('\n%s*$', '')
    return '\n```\n' .. code .. '\n```\n'
  end)
  text = text:gsub('<code[^>]*>(.-)</code>', function(code)
    return '`' .. decode_entities(code) .. '`'
  end)

  text = text:gsub('<img[^>]-src="([^"]-)"[^>]->', function(src)
    local abs = absolutize(decode_entities(src))
    return abs and ('![](' .. abs .. ')') or ''
  end)
  text = text:gsub("<img[^>]-src='([^']-)'[^>]->", function(src)
    local abs = absolutize(decode_entities(src))
    return abs and ('![](' .. abs .. ')') or ''
  end)

  text = text:gsub('<a[^>]-href="([^"]-)"[^>]*>(.-)</a>', function(href, label)
    return '[' .. decode_entities(label) .. '](' .. decode_entities(href) .. ')'
  end)

  text = text:gsub('<strong[^>]*>(.-)</strong>', '**%1**')
  text = text:gsub('<b[^>]*>(.-)</b>', '**%1**')
  text = text:gsub('<em[^>]*>(.-)</em>', '*%1*')
  text = text:gsub('<i[^>]*>(.-)</i>', '*%1*')

  for level = 1, 6 do
    text = text:gsub('<h' .. level .. '[^>]*>(.-)</h' .. level .. '>', function(inner)
      return '\n' .. string.rep('#', level) .. ' ' .. decode_entities(inner) .. '\n'
    end)
  end

  text = text:gsub('<li[^>]*>(.-)</li>', function(item)
    return '\n- ' .. decode_entities(item):gsub('%s+$', '')
  end)
  text = text:gsub('</?[ou]l[^>]*>', '\n')

  text = text:gsub('<tr[^>]*>', '\n| ')
  text = text:gsub('</tr>', ' |')
  text = text:gsub('<t[dh][^>]*>', ' | ')
  text = text:gsub('<table[^>]*>', '\n')
  text = text:gsub('</table>', '\n')

  text = text:gsub('<br%s*/?>', '\n')
  text = text:gsub('</p>', '\n\n')
  text = text:gsub('<p[^>]*>', '\n')
  text = text:gsub('</div>', '\n')
  text = text:gsub('<hr%s*/?>', '\n---\n')

  text = text:gsub('<[^>]->', '')
  text = decode_entities(text)

  text = text:gsub('[ \t]+\n', '\n')
  text = text:gsub('\n\n\n+', '\n\n')
  text = text:gsub('^\n+', '')
  return vim.trim(text)
end

local function sample_block(label, content)
  content = (content or ''):gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\n+$', '')
  return '**' .. label .. '**\n\n```\n' .. content .. '\n```\n'
end

local function example_tests(problem)
  local cfg = problem.problemConfig or {}
  local prog = cfg.programmingProblemConfig or cfg.codeCompletionProblemConfig or {}
  return prog.exampleTestDatas or {}
end

--- Full statement markdown for a problem.
function M.render(problem, opts)
  opts = opts or {}
  local lines = {}
  local id_label = problem.label and (problem.label .. ' ') or ''

  lines[#lines + 1] = '# ' .. id_label .. vim.trim(problem.title or '')
  local cfg = problem.problemConfig or {}
  local prog = cfg.programmingProblemConfig or cfg.codeCompletionProblemConfig or {}
  local meta = string.format('> 题集 %s · 分值 %s · %s',
    opts.psName or problem.problemSetId or '', tostring(problem.score or '?'), problem.type or 'PROGRAMMING')
  if prog.timeLimit then
    meta = meta .. string.format(' · 时间 %ss · 内存 %sKB', tostring(prog.timeLimit), tostring(prog.memoryLimit or '?'))
  end
  lines[#lines + 1] = meta
  if opts.url then
    lines[#lines + 1] = '> ' .. opts.url
  end

  local body = M.html_to_markdown(problem.description)
  if body == '' then
    body = M.html_to_markdown(problem.content)
  end
  if body ~= '' then
    lines[#lines + 1] = '## 题目描述'
    lines[#lines + 1] = body
  end

  local samples = example_tests(problem)
  if #samples > 0 then
    lines[#lines + 1] = '## 样例'
    for i, sample in ipairs(samples) do
      local suffix = #samples == 1 and '' or (' ' .. i)
      lines[#lines + 1] = sample_block((sample.name or '输入') .. suffix, sample.input)
      lines[#lines + 1] = sample_block('输出' .. suffix, sample.output)
    end
  end

  if problem.solution and vim.trim(problem.solution) ~= '' then
    lines[#lines + 1] = '## 官方题解'
    lines[#lines + 1] = M.html_to_markdown(problem.solution)
  end

  return table.concat(lines, '\n\n') .. '\n'
end

--- Open (or focus) a statement in a scratch buffer named pintia://problem/<key>.
function M.open(key, title, markdown)
  local bufname = 'pintia://problem/' .. key
  local bufnr = vim.fn.bufnr('^' .. vim.fn.escape(bufname, '\\') .. '$')
  if bufnr == -1 then
    -- not a 'scratch' buffer: markview/render-markdown ignore buftype=nofile
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, bufname)
  end

  local content = vim.split(markdown, '\n', { plain = true })
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].swapfile = false

  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', '', {
    callback = function()
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end,
    desc = '关闭题面',
  })

  vim.cmd('sbuffer ' .. bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- plays nicely with render-markdown.nvim / markview.nvim / conceal plugins
  if vim.api.nvim_buf_get_name(0) == bufname then
    vim.wo[0].conceallevel = 2
    vim.wo[0].concealcursor = 'nc'
    vim.wo[0].spell = false
  end
  return bufnr
end

return M
