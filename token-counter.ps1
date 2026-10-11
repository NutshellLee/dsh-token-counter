# dsh-token-counter - DSH 大模型用量托盘计数器
# 版本 1.0
#
# 托盘图标显示「今天」消耗的总 token 数（单位：万）。
# 悬停显示今天 / 昨天的 输入、输出、缓存读取、合计。
#
# 数据来源：%USERPROFILE%\.dsh\storages\session_projcache\sessions\*.json
#   这是 DSH 自己写的会话投影缓存（未压缩 JSON），里面每个会话有累计 token 用量。
#   程序每分钟读一次，把「增量」记到当天，所以是按天分开算的。
#
# 说明：这是本机 DSH 的用量，不等于 DeepSeek 后台账单（后台还有时段优惠、其他客户端用量）。
# 不联网，不调用任何模型。
#
# 删除方法：结束进程 + 删除本文件夹 + 删除启动文件夹里的快捷方式。

param(
  [switch]$Once,
  [switch]$Detail,      # 控制台模式：打印明细文本后退出（用于测试）
  [switch]$ShowPanel,   # 只为打开一次面板（手动查看用）
  [int]$IntervalSec = 60
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $Root 'state.json'
$BakPath   = Join-Path $Root 'state.bak.json'
$CacheDir  = Join-Path $env:USERPROFILE '.dsh\storages\session_projcache\sessions'

function Write-Log([string]$m) {
  try { Add-Content -Path (Join-Path $Root 'token-counter.log') -Value "$(Get-Date -Format o) $m" -Encoding UTF8 } catch {}
}

function Get-Num([string]$text, [string]$name) {
  $m = [regex]::Match($text, '"' + $name + '"\s*:\s*(\d+)')
  if ($m.Success) { return [int64]$m.Groups[1].Value }
  return [int64]0
}

function Read-SessionTotals([string]$path) {
  try { $t = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch { return $null }
  $m = [regex]::Match($t, '"tokenUsage"\s*:\s*\{.*?"totals"\s*:\s*\{([^}]*)\}', 'Singleline')
  if (-not $m.Success) { return $null }
  $g = $m.Groups[1].Value
  return [pscustomobject]@{
    In    = Get-Num $g 'uncachedInputTokens'
    Out   = Get-Num $g 'outputTokens'
    Cache = Get-Num $g 'cacheReadTokens'
    Write = Get-Num $g 'cacheWriteTokens'
  }
}

function Load-State {
  if (-not (Test-Path $StatePath)) { return $null }
  try {
    return (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    # 关键：文件读不出来（被写到一半、被截断）**不等于**第一次运行。
    # 以前这里静静地返回 null，于是程序当成新装、建一个空的，然后立刻把空的覆盖回去，
    # 历史就这么整块没了。所以现在：留下残骸、大声记一笔。
    $bad = "$StatePath.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    try { Move-Item -Path $StatePath -Destination $bad -Force } catch {}
    Write-Log "state unreadable -> kept as $(Split-Path $bad -Leaf); trying the backup: $($_.Exception.Message)"
    return $null
  }
}

function Save-State($s) {
  # 先写临时文件再替换：直接覆盖写的话，进程在写的那一刻被杀掉就会留下半个文件
  $json = $s | ConvertTo-Json -Depth 6 -Compress
  $tmp = "$StatePath.tmp"
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -Path $tmp -Destination $StatePath -Force
}

function New-EmptyUsage { return [pscustomobject]@{ in = [int64]0; out = [int64]0; cache = [int64]0; write = [int64]0 } }

function New-State {
  return [pscustomobject]@{
    sessions = [pscustomobject]@{}
    days     = [pscustomobject]@{}
  }
}

function Get-DayKey([datetime]$d) { return $d.ToString('yyyy-MM-dd') }

function Ensure-Day($state, $d) {
  # 参数不加 [string]，否则传进来的 DateTime 会被转成区域格式，键就对不上了
  $key = if ($d -is [datetime]) { $d.ToString('yyyy-MM-dd') } else { [string]$d }
  if (-not $state.days.PSObject.Properties[$key]) {
    $state.days | Add-Member -NotePropertyName $key -NotePropertyValue (New-EmptyUsage)
  }
  return $state.days.$key
}

function Add-Usage($acc, $u) {
  $acc.in += [int64]$u.In; $acc.out += [int64]$u.Out
  $acc.cache += [int64]$u.Cache; $acc.write += [int64]$u.Write
}

# 一轮：把各会话累计值的增量记到当天
function Step($state, [datetime]$now) {
  if (-not (Test-Path $CacheDir)) { return $false }
  $today = Ensure-Day $state $now
  $files = Get-ChildItem $CacheDir -Filter '*.json' -File -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    $id = $f.BaseName
    $cur = Read-SessionTotals $f.FullName
    if ($null -eq $cur) { continue }
    $prevProp = $state.sessions.PSObject.Properties[$id]
    if ($null -ne $prevProp) {
      $p = $prevProp.Value
      $dIn = [int64]$cur.In - [int64]$p.in
      $dOut = [int64]$cur.Out - [int64]$p.out
      $dCa = [int64]$cur.Cache - [int64]$p.cache
      $dWr = [int64]$cur.Write - [int64]$p.write
      # 只有全部非负才认为是真实增量（否则是会话被重建，重新取基线）
      if ($dIn -ge 0 -and $dOut -ge 0 -and $dCa -ge 0 -and $dWr -ge 0) {
        $today.in += $dIn; $today.out += $dOut; $today.cache += $dCa; $today.write += $dWr
      }
      $p.in = [int64]$cur.In; $p.out = [int64]$cur.Out; $p.cache = [int64]$cur.Cache; $p.write = [int64]$cur.Write
    } else {
      $state.sessions | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{
        in = [int64]$cur.In; out = [int64]$cur.Out; cache = [int64]$cur.Cache; write = [int64]$cur.Write
      })
    }
  }
  return $true
}

function Get-DayUsage($state, [string]$d) {
  if ($state.days.PSObject.Properties[$d]) { return $state.days.$d }
  return New-EmptyUsage
}

function Format-N([int64]$n) {
  if ($n -ge 100000000) { return ("{0:0.##}" -f ($n / 100000000.0)) + '亿' }
  if ($n -ge 10000) { return ("{0:0.#}" -f ($n / 10000.0)) + '万' }
  return "$n"
}

function Get-TooltipText($state, [datetime]$now) {
  $t = Get-DayUsage $state (Get-DayKey $now)
  $y = Get-DayUsage $state (Get-DayKey $now.AddDays(-1))
  $tt = [int64]$t.in + [int64]$t.out + [int64]$t.cache
  $yt = [int64]$y.in + [int64]$y.out + [int64]$y.cache
  # 托盘提示只有 63 个字符，六个数字塞进去必然挤。这里只放合计，细项在「明细」窗口里。
  $full = "Token 用量`n今日 $(Format-N $tt)`n昨日 $(Format-N $yt)"
  if ($full.Length -le 63) { return $full }
  return "今 $(Format-N $tt)`n昨 $(Format-N $yt)"
}

function New-CountIcon([int64]$n) {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0, 120, 100))), 0, 0, 31, 31)
  $wan = [int64]($n / 10000)
  if ($wan -gt 9999) { $wan = 9999 }
  $txt = "$wan"
  $size = switch ($txt.Length) { 1 {16} 2 {14} 3 {11} 4 {9} default {7} }
  $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $fmt  = New-Object System.Drawing.StringFormat
  $fmt.Alignment = [System.Drawing.StringAlignment]::Center
  $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
  $g.DrawString($txt, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $fmt)
  $g.Dispose()
  $h = $bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($h)
  $bmp.Dispose()
  return $ico
}

function Get-DetailText($state, [datetime]$now) {
  $d0 = Get-DayKey $now
  $d1 = Get-DayKey $now.AddDays(-1)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("生成时间：$($now.ToString('yyyy-MM-dd HH:mm:ss'))")
  [void]$sb.AppendLine('（本机 DSH 用量，不等于 DeepSeek 后台账单；合计 = 输入 + 输出 + 缓存读取）')
  foreach ($pair in @(@('今天', $d0), @('昨天', $d1))) {
    $u = Get-DayUsage $state $pair[1]
    $tot = [int64]$u.in + [int64]$u.out + [int64]$u.cache
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("【$($pair[0])】$($pair[1])")
    [void]$sb.AppendLine("    输入        $(Format-N $u.in)")
    [void]$sb.AppendLine("    输出        $(Format-N $u.out)")
    [void]$sb.AppendLine("    缓存读取    $(Format-N $u.cache)")
    [void]$sb.AppendLine("    缓存写入    $(Format-N $u.write)")
    [void]$sb.AppendLine("    合计        $(Format-N $tot)")
  }
  return $sb.ToString()
}

function Initialize-WinForms {
  if ($script:WinFormsReady) { return }
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  # 不设成 false 的话控件走 GDI+ 的 DrawString，中文会发虚
  try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
  [System.Windows.Forms.Application]::EnableVisualStyles()
  # 界面里的异常别弹那个吓人的框，写进日志并带上堆栈
  try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
      param($s, $e)
      Write-Log "ui exception: $($e.Exception.ToString())"
    })
  } catch { Write-Log "install ui exception logger failed: $($_.Exception.Message)" }
  $script:WinFormsReady = $true
}

# ---------------------------------------------------------------- 面板（自绘）
# 三个工具共用同一套外观：同一个尺寸、同一套配色、同一种画法。

# 下面要用 System.Drawing 的类型，先把程序集加载进来（不加载会报找不到类型）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 查鼠标左键此刻是不是按着：用来判断「点到面板外面了」
Add-Type -Namespace TokenUi -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@ -ErrorAction SilentlyContinue

$script:UiBg    = [System.Drawing.Color]::FromArgb(255, 249, 250, 251)
$script:UiText  = [System.Drawing.Color]::FromArgb(255, 28, 32, 38)
$script:UiMuted = [System.Drawing.Color]::FromArgb(255, 138, 147, 158)
$script:UiWork  = [System.Drawing.Color]::FromArgb(255, 45, 108, 223)
$script:UiFun   = [System.Drawing.Color]::FromArgb(255, 240, 148, 65)
$script:UiGreen = [System.Drawing.Color]::FromArgb(255, 58, 167, 109)
$script:UiTrack = [System.Drawing.Color]::FromArgb(255, 232, 236, 241)
$script:UiLine  = [System.Drawing.Color]::FromArgb(255, 222, 227, 233)

function Get-UiFonts {
  if (-not $script:FTitle) {
    $script:FTitle = New-Object System.Drawing.Font 'Microsoft YaHei UI', 21, ([System.Drawing.FontStyle]::Bold)
    $script:FTab   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $script:FTabB  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5, ([System.Drawing.FontStyle]::Bold)
    $script:FSub   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FApp   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $script:FTiny  = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5
    # 关闭按钮单独一个大字号，原来那个 × 太小
    $script:FClose = New-Object System.Drawing.Font 'Microsoft YaHei UI', 14, ([System.Drawing.FontStyle]::Regular)
  }
}

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  if ($r -le 0 -or $w -le 0 -or $h -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF $x, $y, $w, $h)); return $p }
  if ($r -gt $h / 2) { $r = $h / 2 }
  if ($r -gt $w / 2) { $r = $w / 2 }
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# 面板上某个档期的用量（今天/昨天/近 7 天）
function Get-PanelUsage($state, [datetime]$now, [int]$rng) {
  if ($rng -ne 2) { return Get-DayUsage $state (Get-DayKey $now.AddDays(-$rng)) }
  $acc = New-EmptyUsage
  for ($i = 0; $i -lt 7; $i++) {
    $u = Get-DayUsage $state (Get-DayKey $now.AddDays(-$i))
    $acc.in    = [int64]$acc.in    + [int64]$u.in
    $acc.out   = [int64]$acc.out   + [int64]$u.out
    $acc.cache = [int64]$acc.cache + [int64]$u.cache
    $acc.write = [int64]$acc.write + [int64]$u.write
  }
  return $acc
}

# 自绘面板必须开双缓冲，不然定时重画时整块会闪一下。
# DoubleBuffered 是受保护的属性，直接赋值得反射；用 Control.SetStyle 更稳。
function Set-PanelDoubleBuffer($form) {
  try {
    $styles = [int]([System.Windows.Forms.ControlStyles]::UserPaint)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer)
    $styles = $styles -bor [int]([System.Windows.Forms.ControlStyles]::Opaque)
    $m = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'NonPublic,Instance')
    [void]$m.Invoke($form, @([System.Windows.Forms.ControlStyles]$styles, $true))
  } catch { Write-Log "double buffer unavailable: $($_.Exception.Message)" }
}

# 面板高度：底部那排柱子只有「近 7 天」才有，别的栏不留那块空的
function Get-TokenPanelHeight([int]$rng) {
  if ($rng -eq 2) { return (176 + 4 * 24 + 78) }
  return (176 + 4 * 24 + 16)
}

function Draw-Panel($g, [int]$w, [int]$h) {
  Get-UiFonts
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear($script:UiBg)

  $now = Get-Date
  $st = $script:State
  $rng = [int]$script:PanelRange
  $u = Get-PanelUsage $st $now $rng
  $tot = [int64]$u.in + [int64]$u.out + [int64]$u.cache

  $bText = New-Object System.Drawing.SolidBrush $script:UiText
  $bMuted = New-Object System.Drawing.SolidBrush $script:UiMuted

  # ---- 顶部三个标签
  $tabs = @('今天', '昨天', '近 7 天')
  $tx = 16
  $script:TabRects = @()
  for ($i = 0; $i -lt 3; $i++) {
    $fnt = if ($i -eq $rng) { $script:FTabB } else { $script:FTab }
    $col = if ($i -eq $rng) { $script:UiWork } else { $script:UiMuted }
    $sz = $g.MeasureString($tabs[$i], $fnt)
    $br = New-Object System.Drawing.SolidBrush $col
    $g.DrawString($tabs[$i], $fnt, $br, $tx, 12)
    $br.Dispose()
    $script:TabRects += [pscustomobject]@{ x = $tx; w = [int]$sz.Width; i = $i }
    if ($i -eq $rng) {
      $pen = New-Object System.Drawing.Pen $script:UiWork, 2
      $g.DrawLine($pen, $tx, 32, $tx + $sz.Width - 2, 32)
      $pen.Dispose()
    }
    $tx += [int]$sz.Width + 18
  }

  # 右上角关闭按钮
  $g.DrawString('×', $script:FClose, $bMuted, ($w - 30), 2)
  $script:PanelCloseRect = [pscustomobject]@{ x = ($w - 40); y = 0; w = 36; h = 34 }

  # ---- 大字号：合计
  $big = Format-N $tot
  $g.DrawString($big, $script:FTitle, $bText, 14, 44)
  $szBig = $g.MeasureString($big, $script:FTitle)
  $g.DrawString("输入 $(Format-N $u.in)   ·   输出 $(Format-N $u.out)   ·   缓存读取 $(Format-N $u.cache)", $script:FSub, $bMuted, 18, 40 + $szBig.Height)

  # ---- 三条占比色条
  $barY = 118; $barX = 16; $barW = $w - 32; $barH = 12
  $gp = New-RoundRect $barX $barY $barW $barH 6
  $tb = New-Object System.Drawing.SolidBrush $script:UiTrack
  $g.FillPath($tb, $gp); $tb.Dispose(); $gp.Dispose()
  if ($tot -gt 0) {
    $segs = @(
      [pscustomobject]@{ v = [int64]$u.in;    c = $script:UiWork },
      [pscustomobject]@{ v = [int64]$u.out;   c = $script:UiFun },
      [pscustomobject]@{ v = [int64]$u.cache; c = $script:UiGreen }
    )
    $dx = [single]$barX
    foreach ($s in $segs) {
      if ($s.v -le 0) { continue }
      $sw = [single]($barW * $s.v / $tot)
      if ($sw -lt 1) { $sw = 1 }
      $gp = New-RoundRect $dx $barY $sw $barH 6
      $b = New-Object System.Drawing.SolidBrush $s.c
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      $dx += $sw
    }
  }

  # ---- 四项明细
  $g.DrawString('明细', $script:FTabB, $bText, 16, 142)
  $rows = @(
    [pscustomobject]@{ n = '输入';      v = [int64]$u.in;    c = $script:UiWork },
    [pscustomobject]@{ n = '输出';      v = [int64]$u.out;   c = $script:UiFun },
    [pscustomobject]@{ n = '缓存读取';  v = [int64]$u.cache; c = $script:UiGreen },
    [pscustomobject]@{ n = '缓存写入';  v = [int64]$u.write; c = [System.Drawing.Color]::FromArgb(255, 140, 150, 165) }
  )
  $maxR = 1
  foreach ($r in $rows) { if ($r.v -gt $maxR) { $maxR = [int64]$r.v } }
  $y = 164
  foreach ($r in $rows) {
    $g.DrawString($r.n, $script:FApp, $bText, 16, $y)
    $bx = 132; $bw = 190; $bh = 9
    $gp = New-RoundRect $bx ($y + 3) $bw $bh 4
    $b = New-Object System.Drawing.SolidBrush $script:UiTrack
    $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    if ($r.v -gt 0) {
      $wv = [single]($bw * $r.v / $maxR)
      $gp = New-RoundRect $bx ($y + 3) $wv $bh 4
      $b = New-Object System.Drawing.SolidBrush $r.c
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    $g.DrawString((Format-N $r.v), $script:FApp, $bText, ($w - 16 - 60), $y)
    $y += 24
  }

  # ---- 底部：只有「近 7 天」这一栏画每天一根竖条。
  # 今天/昨天底下不放它：那两栏讲的是当天，摆一周的柱子只是占地方。
  # 鼠标停在哪根上，那根高亮，并在它上方写出日期和数字。
  $script:BarRects = @()
  if ($rng -eq 2) {
    $baseY = $h - 40
    $dayW = [int](($w - 32) / 7)
    $vals = @()
    $maxD = [int64]1
    for ($i = 6; $i -ge 0; $i--) {
      $dd = $now.AddDays(-$i)
      $du = Get-DayUsage $st (Get-DayKey $dd)
      $dv = [int64]$du.in + [int64]$du.out + [int64]$du.cache
      $vals += [pscustomobject]@{ d = $dd; v = $dv }
      if ($dv -gt $maxD) { $maxD = $dv }
    }
    $idx = 0
    foreach ($v in $vals) {
      $bx = 16 + $idx * $dayW
      $bh2 = [int](28 * $v.v / $maxD)
      if ($bh2 -lt 1 -and $v.v -gt 0) { $bh2 = 1 }
      $hot = ([int]$script:PanelBarHover -eq $idx)
      if ($bh2 -gt 0) {
        $gp = New-RoundRect ($bx + 6) ($baseY + 24 - $bh2) ($dayW - 14) $bh2 3
        $bc = if ($hot) { $script:UiFun } elseif ($idx -eq 6) { $script:UiWork } else { [System.Drawing.Color]::FromArgb(255, 150, 175, 235) }
        $b = New-Object System.Drawing.SolidBrush $bc
        $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
      }
      $bt = New-Object System.Drawing.SolidBrush $(if ($hot) { $script:UiText } else { $script:UiMuted })
      $g.DrawString($v.d.ToString('MM-dd'), $script:FTiny, $bt, ($bx + 2), ($baseY + 26))
      $bt.Dispose()
      $script:BarRects += [pscustomobject]@{ i = $idx; x = $bx; w = $dayW }
      $idx++
    }
    $hv = [int]$script:PanelBarHover
    if ($hv -ge 0 -and $hv -lt $vals.Count) {
      $one = $vals[$hv]
      $htxt = $one.d.ToString('MM-dd') + '  ' + (Format-N $one.v)
      $hb = New-Object System.Drawing.SolidBrush $script:UiText
      $hw = $g.MeasureString($htxt, $script:FTiny).Width
      $hx = 16 + $hv * $dayW + ($dayW - $hw) / 2
      if ($hx -lt 16) { $hx = 16 }
      if ($hx + $hw -gt ($w - 8)) { $hx = $w - 8 - $hw }
      $g.DrawString($htxt, $script:FTiny, $hb, [single]$hx, [single]($baseY - 14))
      $hb.Dispose()
    }
  }
  $bText.Dispose(); $bMuted.Dispose()
}

function Show-Panel($state, [datetime]$now) {
  try {
    Initialize-WinForms
    if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() }
    $script:PanelRange = 0
    $script:PanelReady = $false
    $script:PanelBarHover = -1
    $script:BarRects = @()
    $script:PanelHold = $false
    $w = 520
    $h = Get-TokenPanelHeight 0
    $f = New-Object System.Windows.Forms.Form
    Set-PanelDoubleBuffer $f
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = $script:UiBg
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ClientSize = New-Object System.Drawing.Size $w, $h
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point (($wa.Right - $w - 10), ($wa.Bottom - $h - 10))
    $f.Add_Paint({ param($s, $e) Draw-Panel $e.Graphics $s.ClientSize.Width $s.ClientSize.Height })
    $f.Add_MouseClick({
      param($s, $e)
      $cr = $script:PanelCloseRect
      if ($cr -and $e.X -ge $cr.x -and $e.X -le ($cr.x + $cr.w) -and $e.Y -ge $cr.y -and $e.Y -le ($cr.y + $cr.h)) { $s.Close(); return }
      foreach ($t in $script:TabRects) {
        if ($e.Y -ge 8 -and $e.Y -le 34 -and $e.X -ge $t.x -and $e.X -le ($t.x + $t.w + 8)) {
          $script:PanelRange = $t.i
          # 高度跟着栏目走：底部那排柱子只有近 7 天才有，别在别处留一块空的
          $nh = Get-TokenPanelHeight $t.i
          $s.ClientSize = New-Object System.Drawing.Size 520, $nh
          $wa2 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
          $s.Location = New-Object System.Drawing.Point (($wa2.Right - 520 - 10), ($wa2.Bottom - $nh - 10))
          $s.Invalidate()
          return
        }
      }
    })
    $f.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:PanelHold = $true } })
    $f.Add_MouseUp({ param($s, $e) $script:PanelHold = $false })
    # 底部柱子：鼠标进来就高亮那一根，并把它的日期和数字写在上面
    $f.Add_MouseMove({
      param($s, $e)
      $hot = -1
      foreach ($br in @($script:BarRects)) {
        if ($e.Y -ge ($s.ClientSize.Height - 58) -and $e.X -ge $br.x -and $e.X -lt ($br.x + $br.w)) { $hot = [int]$br.i; break }
      }
      if ($hot -ne [int]$script:PanelBarHover) { $script:PanelBarHover = $hot; $s.Invalidate() }
    })
    $f.Add_MouseLeave({
      param($s, $e)
      if ([int]$script:PanelBarHover -ne -1) { $script:PanelBarHover = -1; $s.Invalidate() }
    })
    # 点别处收起来；延迟半秒再武装，免得菜单刚关掉时的那次失焦把它关掉
    $f.Add_Shown({
      $script:PanelArm = New-Object System.Windows.Forms.Timer
      $script:PanelArm.Interval = 500
      $script:PanelArm.Add_Tick({ $script:PanelArm.Stop(); $script:PanelReady = $true })
      $script:PanelArm.Start()
    })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape' -or $e.KeyCode -eq 'Space') { $s.Close() } })
    # 关闭方式：**只有点到面板外面才关**。以前挂在 Deactivate 上，一切换焦点就关，
    # 想看一眼、截个图都来不及。这里每 150 毫秒看一眼鼠标左键是不是按在面板外。
    $script:PanelWatch = New-Object System.Windows.Forms.Timer
    $script:PanelWatch.Interval = 150
    $script:PanelWatch.Add_Tick({
      try {
        if (-not $script:PanelForm -or $script:PanelForm.IsDisposed) { $script:PanelWatch.Stop(); return }
        $r = $script:PanelForm.RectangleToScreen($script:PanelForm.ClientRectangle)
        $pos = [System.Windows.Forms.Cursor]::Position
        $inside = ($pos.X -ge $r.Left -and $pos.X -le $r.Right -and $pos.Y -ge $r.Top -and $pos.Y -le $r.Bottom)
        # 别的工具后来开了明细面板，就先把我的收起来，只留一个
        try {
          $ownerFile = Join-Path $env:TEMP 'dsh-tray-panel.owner'
          if (Test-Path $ownerFile) {
            $parts = (Get-Content $ownerFile -Raw -ErrorAction SilentlyContinue).Trim() -split '\|'
            if ($parts.Count -eq 2 -and $parts[0] -ne 'dsh-token-counter') {
              if ([long]$parts[1] -gt [long]$script:PanelOpenedAt) { $script:PanelForm.Close(); return }
            }
          }
        } catch {}
        # 面板开着时每 13 次心跳（约 2 秒）核一次数字：数字变了才重画，没变就不碰屏幕。
        $script:PanelTickN = [int]$script:PanelTickN + 1
        if (($script:PanelTickN % 13) -eq 0) {
          $tu = Get-PanelUsage $script:State (Get-Date) ([int]$script:PanelRange)
          $tsig = "$($script:PanelRange)|$($tu.in)|$($tu.out)|$($tu.cache)|$($tu.write)"
          if ($tsig -ne [string]$script:PanelSig) { $script:PanelSig = $tsig; $script:PanelForm.Invalidate() }
        }
        # 任务栏/托盘那一带不算「点到别处」：不然点托盘图标开面板时，按下的那一刻就被
        # 判成点在面板外，面板先关一次再被点开，看着就是「闪一下又弹出来」。
        $waNow = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $onTaskbar = ($pos.Y -gt $waNow.Bottom -or $pos.Y -lt $waNow.Top -or $pos.X -gt $waNow.Right -or $pos.X -lt $waNow.Left)
        $downNow = ([TokenUi.Keys]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
        if (-not $downNow) { $script:PanelHold = $false }
        # 在面板里按下去再拖到面板外松手不算「点别处」，否则拖滚动条手滑出边界就会把面板关掉
        if (-not $inside -and -not $onTaskbar -and -not $script:PanelHold -and $downNow) {
          $script:PanelForm.Close()
        }
      } catch {}
    })
    $script:PanelWatch.Start()
    $script:PanelTickN = 0
    $script:PanelForm = $f
    # 三个工具的明细面板同一时刻只留一个，别在右下角叠成一摞
    $script:PanelOpenedAt = [DateTime]::UtcNow.Ticks
    try { [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'dsh-tray-panel.owner'), "dsh-token-counter|$($script:PanelOpenedAt)") } catch {}
    $f.Show()
    $f.Activate()
  } catch { Write-Log "panel failed: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)" }
}

function Update-Tray {
  try {
    [void](Step $script:State (Get-Date))
    $now = Get-Date
    $t = Get-DayUsage $script:State (Get-DayKey $now)
    $tot = [int64]$t.in + [int64]$t.out + [int64]$t.cache
    if ($tot -ne $script:LastTotal) { $script:Ni.Icon = New-CountIcon $tot; $script:LastTotal = $tot }
    $script:Ni.Text = Get-TooltipText $script:State $now
    Save-State $script:State
  } catch {
    Write-Log "tick failed: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
  }
}

function Start-Tray {
  Initialize-WinForms

  $script:LastTotal = -1
  $script:Ni = New-Object System.Windows.Forms.NotifyIcon
  $script:Ni.Icon = New-CountIcon 0
  $script:Ni.Text = '大模型用量计数器 启动中'
  $script:Ni.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miDetail = $menu.Items.Add('明细')
  $miNow    = $menu.Items.Add('立即刷新')
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $miOpen   = $menu.Items.Add('打开所在文件夹')
  $miExit   = $menu.Items.Add('退出')
  $script:Ni.ContextMenuStrip = $menu

  # 左键单击托盘图标开明细。已经开着就什么都不做——不重开也不收起来，
  # 免得点一下先收再弹、看着像闪了一下。收起还是靠点面板外或右上角的叉。
  $script:Ni.Add_MouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    try {
      if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { return }
      Update-Tray
      Show-Panel $script:State (Get-Date)
    } catch { Write-Log "left click failed: $($_.Exception.Message)" }
  })

  $miDetail.Add_Click({ Update-Tray; Show-Panel $script:State (Get-Date) })
  # 只重读，不弹窗：跟「明细」分工明确，也和视频计数器那个保持一致
  $miNow.Add_Click({ Update-Tray })
  $miOpen.Add_Click({ Start-Process explorer.exe $Root })
  $miExit.Add_Click({
    $script:Timer.Stop(); Save-State $script:State
    $script:Ni.Visible = $false; $script:Ni.Dispose()
    [System.Windows.Forms.Application]::Exit()
  })

  $script:Timer = New-Object System.Windows.Forms.Timer
  $script:Timer.Interval = [int]($script:IntervalSec * 1000)
  $script:Timer.Add_Tick({ Update-Tray })
  $script:Timer.Start()

  Write-Log "tray started, interval=$($script:IntervalSec)s"
  Update-Tray
  [System.Windows.Forms.Application]::Run()
}

# ---------------------------------------------------------------- 入口

$state = Load-State
# 状态读不出来时，先试着用上一次的备份救回来
if ($null -eq $state -and (Test-Path $BakPath)) {
  try {
    $bak = Get-Content $BakPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($bak -and $bak.PSObject.Properties['days']) {
      $state = $bak
      Write-Log 'state missing or unreadable -> restored from state.bak.json'
    }
  } catch { Write-Log "backup unreadable: $($_.Exception.Message)" }
}
if ($null -eq $state) { $state = New-State }
foreach ($f in 'sessions','days') {
  if (-not $state.PSObject.Properties[$f]) { $state | Add-Member -NotePropertyName $f -NotePropertyValue ([pscustomobject]@{}) }
}

# 修历史 bug：早期版本把日期键写成了区域格式（10/10/2026 23:50:18），
# 结果每一分钟都记进了各自的小桶，导致当天总数一直不涨。这里合并回 yyyy-MM-dd。
$bad = @($state.days.PSObject.Properties | Where-Object { $_.Name -notmatch '^\d{4}-\d{2}-\d{2}$' })
if ($bad.Count -gt 0) {
  $merged = 0
  foreach ($p in $bad) {
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($p.Name, [ref]$parsed)) {
      $k = $parsed.ToString('yyyy-MM-dd')
      if (-not $state.days.PSObject.Properties[$k]) { $state.days | Add-Member -NotePropertyName $k -NotePropertyValue (New-EmptyUsage) }
      $state.days.$k.in    += [int64]$p.Value.in
      $state.days.$k.out   += [int64]$p.Value.out
      $state.days.$k.cache += [int64]$p.Value.cache
      $state.days.$k.write += [int64]$p.Value.write
      $merged++
    }
    $state.days.PSObject.Properties.Remove($p.Name)
  }
  Write-Log "merged $merged malformed day keys back into yyyy-MM-dd"
  Save-State $state
}

# 每次启动留一份上一版的备份。只在这份确实有内容时才覆盖，免得把好备份冲成空的。
if ((Test-Path $StatePath) -and (@($state.days.PSObject.Properties).Count -gt 0)) {
  try { Copy-Item -Path $StatePath -Destination $BakPath -Force } catch { Write-Log "backup failed: $($_.Exception.Message)" }
}

if ($Once) {
  [void](Step $state (Get-Date))
  Save-State $state
  $now = Get-Date
  $t = Get-DayUsage $state (Get-DayKey $now)
  $y = Get-DayUsage $state (Get-DayKey $now.AddDays(-1))
  "today    in=$($t.in) out=$($t.out) cache=$($t.cache) total=$([int64]$t.in+[int64]$t.out+[int64]$t.cache)"
  "yesterday in=$($y.in) out=$($y.out) cache=$($y.cache) total=$([int64]$y.in+[int64]$y.out+[int64]$y.cache)"
  "tooltip  : $(Get-TooltipText $state $now -replace "`n", ' | ')"
  "sessions tracked: $(@($state.sessions.PSObject.Properties).Count)"
  exit 0
}

if ($Detail) {
  [void](Step $state (Get-Date))
  Save-State $state
  Get-DetailText $state (Get-Date)
  exit 0
}

if ($ShowPanel) {
  [void](Step $state (Get-Date))
  Save-State $state
  $script:State = $state
  Show-Panel $state (Get-Date)
  [System.Windows.Forms.Application]::Run($script:PanelForm)
  exit 0
}

$script:State = $state
$script:IntervalSec = $IntervalSec

$script:SingleInstance = New-Object System.Threading.Mutex($false, 'Local\dsh-token-counter-singleton')
if (-not $script:SingleInstance.WaitOne(0)) { Write-Log 'another instance is already running, exiting'; exit 0 }

Start-Tray
