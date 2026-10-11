# AGENTS.md

给改动这个工具的 AI 或开发者看的。只写代码里看不出来的东西。
用户怎么装怎么用写在 README.md 里，这里不重复。

## 数据来源（不要换成别的）

- 只读 `%USERPROFILE%\.dsh\storages\session_projcache\sessions\*.json`。
  每个文件里 `record.rows.tokenUsage.val.totals` 是该会话的**累计**用量，四个字段：
  `uncachedInputTokens` / `outputTokens` / `cacheReadTokens` / `cacheWriteTokens`。
- 这份是未压缩 JSON，PowerShell 能直接读。
  会话原始记录在 `.dsh\sessions\*\session.v4.jsonl.zstd`，是 zstd 且由几百个独立帧拼接而成，
  **PowerShell 解不了**：系统没有 zstd 工具，`tar` 不认裸流，Node 的解压函数也只解第一帧就停，
  而且不报错、静默返回一个几乎空的字符串。要用原始记录只有走 Node，并自己按魔数切帧。

## 致命坑（每一个都真实发生过）

- **日期键必须是 `yyyy-MM-dd`；`Ensure-Day` 这类函数的参数不要声明成 `[string]`。**
  声明成字符串后传 DateTime 进去会被转成区域格式（`10/10/2026 23:50:18`），
  于是每分钟新建一个键，日合计永远停在初始值，界面上完全看不出错。
  修复时要顺手把已经产生的碎键合并回当天（入口处有这段迁移代码）。
- **累计值只增不减。** 算增量时出现负数，说明会话被重建，这时只更新基线、不计入当天。
- **首次运行要把基线取成当前值**，否则会把会话的历史累计整块算到今天。
- 主程序不能自己去做网络请求：取时长是独立进程，写 `durations.json`，主程序只读。

## 平台硬限制

- `NotifyIcon.Text` 上限 **63 个字符**，64 个就抛异常。所以托盘提示只放得下合计，
  细项必须放明细窗口；任何拼提示文本的地方都要有回退分支。
- 创建任何控件之前要调用 `Application.SetCompatibleTextRenderingDefault($false)`，
  否则中文走 GDI+ 渲染，发虚。
- `.ps1` 必须存成 UTF-8 带 BOM，PowerShell 5.1 按 ANSI 读。
  注意：用编辑器或替换类工具改完这个文件之后 BOM 可能会丢，改完检查前三个字节是不是 EF BB BF。

## 明细面板（自绘）

- 明细是**自绘的弹出面板**，不是文字窗口。同一个尺寸（宽 420）、同一套配色、同一种画法，
  和另外两个工具（screen-time-counter、video-tab-counter）保持一致。
  点托盘图标右键 → 明细，从右下角弹出，点别处自动收起。
- 面板内容：顶部三个标签（今天 / 昨天 / 近 7 天）→ 大字合计 → 小字（输入 / 输出 / 缓存读取）
  → 三段占比色条（输入蓝、输出橙、缓存读取绿）→ 四项明细的横条 → 底部近 7 天每天一根竖条。
- 改这块时踩过的坑，一个都别重犯：
  - **用 `System.Drawing` 的类型之前必须先 `Add-Type -AssemblyName System.Drawing`。**
    不加载会报「Unable to find type [System.Drawing.Color]」，而且是在脚本顶层就炸，托盘根本起不来。
  - **事件处理脚本块一定要写 `param($s, $e)`，不要用 `$_`。** 委托调用时 `$_` 是空的。
  - **计时器要放 `$script:` 作用域，不要用闭包变量。** 闭包所在的作用域销毁后变量变成 null，
    计时器一触发就报「不能对 Null 值表达式调用方法」，表现为面板一打开就崩。
  - `Initialize-WinForms` 里装了 `Application.add_ThreadException`，界面异常会连堆栈写进
    `token-counter.log`。别删——没有它只会弹一个没有堆栈的框，极难查。
- 面板是只读展示，没有输入控件；用户要的是只读，不是可编辑。
- 提示和明细里**不写**实现说明（数据来源、口径推导那一类）。属于本文件和代码注释的，
  不要出现在用户界面上。
- **公开的文档和界面里，不出现「使用量」数据**：本机烧了多少 token，真的假的都不行，
  摆出一组具体的数，读的人就会当成作者本人的用量记录。
  要说明界面时，用文字描述「有哪几行、每行是什么」，不要贴「示例输出」。
- **但性能数据必须写真实的**：一次读取耗时多少、轮询间隔、内存占用。
  这类数字跟作者用了多少 token 无关，是判断这套做法值不值得用的依据。

## 验证方式

- **改完先跑一次未定义命令扫描**：用 `[System.Management.Automation.Language.Parser]::ParseFile()`
  建 AST，收集所有 `FunctionDefinitionAst` 名字，再比对所有 `CommandAst` 的 `GetCommandName()`。
  已知命令那一侧要用 `Get-Command` 去取这台机器上真实存在的命令，
  **不要手写一份白名单**——手写的漏一个内置命令（比如 `Add-Content`）就会报假警。
  改函数名漏改调用点这类错在托盘里是静默的，静态扫一下就能抓到。
- **改完托盘相关代码，必须真的点一遍右键菜单的每一项**（明细 / 立即刷新 / 打开文件夹 / 退出）。
- `token-counter.ps1 -Once`   打印今天/昨天的四项、合计和提示文本
- `token-counter.ps1 -Detail` 打印明细文本
- 改完等一分钟，确认 `state.json` 里当天的合计在涨；再对着 projcache 的累计值核一遍。
