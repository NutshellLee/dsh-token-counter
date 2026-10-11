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
  if (Test-Path $StatePath) { try { return (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
  return $null
}

function Save-State($s) {
  $json = $s | ConvertTo-Json -Depth 6 -Compress
  [System.IO.File]::WriteAllText($StatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
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

  # ---- 底部：近 7 天每天一根竖条
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
    if ($bh2 -gt 0) {
      $gp = New-RoundRect ($bx + 6) ($baseY + 24 - $bh2) ($dayW - 14) $bh2 3
      $b = New-Object System.Drawing.SolidBrush $(if ($idx -eq 6) { $script:UiWork } else { [System.Drawing.Color]::FromArgb(255, 150, 175, 235) })
      $g.FillPath($b, $gp); $b.Dispose(); $gp.Dispose()
    }
    $g.DrawString($v.d.ToString('MM-dd'), $script:FTiny, $bMuted, ($bx + 2), ($baseY + 26))
    $idx++
  }
  $bText.Dispose(); $bMuted.Dispose()
}

function Show-Panel($state, [datetime]$now) {
  try {
    Initialize-WinForms
    if ($script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() }
    $script:PanelRange = 0
    $script:PanelReady = $false
    $w = 420
    $h = 176 + 4 * 24 + 78
    $f = New-Object System.Windows.Forms.Form
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
      foreach ($t in $script:TabRects) {
        if ($e.Y -ge 8 -and $e.Y -le 34 -and $e.X -ge $t.x -and $e.X -le ($t.x + $t.w + 8)) {
          $script:PanelRange = $t.i
          $s.Invalidate()
          return
        }
      }
    })
    # 点别处收起来；延迟半秒再武装，免得菜单刚关掉时的那次失焦把它关掉
    $f.Add_Shown({
      $script:PanelArm = New-Object System.Windows.Forms.Timer
      $script:PanelArm.Interval = 500
      $script:PanelArm.Add_Tick({ $script:PanelArm.Stop(); $script:PanelReady = $true })
      $script:PanelArm.Start()
    })
    $f.Add_Deactivate({ if ($script:PanelReady -and $script:PanelForm -and -not $script:PanelForm.IsDisposed) { $script:PanelForm.Close() } })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
    $script:PanelForm = $f
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
