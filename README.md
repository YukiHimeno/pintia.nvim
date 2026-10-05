# pintia.nvim

拼题A（[pintia.cn](https://pintia.cn)）在 Neovim 里。

```
┌───────────────────────────── Pintia 题集 ──────────────────────────────┐
│> 编程题集                                                              │
│ 输入模糊过滤 · <C-n>/<C-p> 选择 · <CR> 打开 · <C-o> 只看题面 · Esc 关闭 │
│─────────────────────────────────────────────────────────────────────────│
│    1001   A1001  Hello World                             10分          │
└─────────────────────────────────────────────────────────────────────────┘
```

## 使用

一个命令进去，之后只用方向键：

```
:Pintia
```
> 亦可在设置中换成 :PTA

面板分四段：操作（题集、提交等入口）、当前工作区信息、最近题目、账号状态。`j/k` 移动，回车执行，`q` 关闭。

- 题集/题目列表里回车 = 拉取到工作区：题面 buffer + 源码 + `tcd` 到题目目录；`<C-o>` 只看题面
- 本地测试用本地编译器跑样例，提交走拼题A云端判题；未登录时先 `:PintiaLogin`
- 最近题目直接回车就能回到对应工作区
- 提交/测试前会自动保存工作区里未保存的修改：就地写入，不动窗口布局、标签页和焦点

插件不注册任何默认键位：

```lua
vim.keymap.set('n', '<leader>p', '<cmd>Pintia<cr>', { desc = 'pintia' })
```

所有功能也是普通函数：`require('pintia').problem_sets()`、`.problems()`、`.test()`、`.submit_cmd()`、`.watch()`。

### 列表界面

`picker = 'auto'`（默认）在检测到 snacks.nvim、telescope.nvim 或 fzf-lua 时把列表交给 `vim.ui.select`；一个都没有时用内置浮动选择器（中文子序列过滤）。想固定某一种：`picker = 'builtin'` 或 `picker = 'ui'`。

内置选择器里：直接输入即过滤，`↑`/`↓`（或 `<C-n>`/`<C-p>`）移动高亮、回车打开；按一次 `Esc` 进入普通模式，那里 `j`/`k`/方向键也能走、`i` 回到过滤输入、`q` 关闭。

## 安装

依赖 Neovim 0.10+（用到 `vim.system`），外部只有命令行工具 `curl`。

手动安装（零配置）：

```bash
git clone https://github.com/YOURNAME/pintia.nvim \
  ~/.config/nvim/pack/pintia/start/pintia.nvim
```

或者直接把它放进 runtimepath：

```lua
vim.opt.rtp:prepend('~/src/pintia.nvim')
```

调整默认值可以调用 `setup()`，也可以直接用 `:PintiaSetup` 在面板里改（保存到 `config.json`，重启仍生效，且优先于 `setup()`；留空恢复默认）。

```lua
require('pintia').setup({
  -- workdir = vim.fn.stdpath('data') .. '/pintia/workspace',
  -- session_file = vim.fn.stdpath('data') .. '/pintia/session.json',
  -- poll_interval = 2000,
  -- judge_timeout = 180,
  -- picker = 'auto',          -- 'auto' | 'builtin' | 'ui'
  -- default_language = 'C++ (g++)',
  -- command_prefix = 'Pintia', -- 注册命令的前缀：'Pintia' 或 'PTA'
})
```

## 登录

`:PintiaLogin` 弹出菜单，支持三种方式：

1. **微信扫码登录**：终端直接显示二维码（需要 `qrencode`，否则打印网页链接），微信扫码确认后自动保存会话
2. **账号密码登录**：邮箱/手机号 + 密码。注意拼题A 的登录接口强制极验验证码，外部客户端遇到时会提示改用微信/Cookie 方式
3. **PTASession cookie 登录**：粘贴浏览器里的 cookie

会话保存到 `session.json`，下次启动直接可用。`:PintiaLogout` 退出。

## 命令

下面以 `:Pintia*` 为例；把 `command_prefix` 设成 `'PTA'` 后，同样的命令注册为 `:PTA*`（例如 `:PTASubmit`），并立即注销旧前缀。在 `:PintiaSetup` 里也能切换。

| 命令 | 说明 |
| --- | --- |
| `:Pintia` | 浮动操作面板（推荐入口） |
| `:PintiaSetup` | 交互式设置：工作区目录、列表界面、超时等 |
| `:PintiaLogin` / `:PintiaLogout` | 登录 / 退出 |
| `:PintiaStatus` | 账号、工作区、样例、源码一览 |
| `:PintiaProblemSets` | 题集选择器 |
| `:PintiaProblems <psID> [名称]` | 指定题集的题目列表 |
| `:PintiaTest` | 本地编译器跑样例（函数题自动嵌入裁判程序） |
| `:PintiaSubmit [文件]` | 提交当前文件并跟踪判题 |
| `:PintiaWatch [submissionId]` | 监视判题（缺省盯当前题最近一次提交） |
| `:PintiaHealth` | 环境自检（curl / 编译器 / 会话） |

## 工作区

```
<workdir>/
└── <题集名>/
    └── A1001-Hello_World/
        ├── statement.md    # 题面（markdown）
        ├── meta.json       # 题集ID/题目ID/语言所需信息
        ├── main.cpp        # 你的代码
        └── samples/1.in 1.out   # 样例
```

在题目目录（或其子目录）里打开任意文件，`:PintiaTest` / `:PintiaSubmit` / `:PintiaWatch` 都会自动找到工作区。

## 说明

- 会话走站点自身的 REST API（与网页前端同一套），登录后所有请求带 `PTASession` cookie
- `:PintiaTest` 在本地编译并跑 samples/；函数题（CODE_COMPLETION）会把你的代码嵌入裁判测试程序样例后编译运行。判题提交仍走拼题A云端。
- 判题码 `WAITING`/`JUDGING`（或 `queued >= 0`）表示仍在评测，轮询间隔与超时可在 `opts` 里调整

## 致谢

[vscode-pintia](https://github.com/jinzcdev/vscode-pintia)

## License

MIT
