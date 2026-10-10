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
  $script:WinFormsReady = $true
}

function Show-Detail($state, [datetime]$now) {
  try {
    Initialize-WinForms
    if ($script:DetailForm -and -not $script:DetailForm.IsDisposed) { $script:DetailForm.Close() }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '大模型 token 用量'
    $f.Size = New-Object System.Drawing.Size 520, 480
    $f.StartPosition = 'CenterScreen'
    $f.MinimizeBox = $false

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.AutoScroll = $true
    $panel.BackColor = [System.Drawing.SystemColors]::Window

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.UseMnemonic = $false
    $label.UseCompatibleTextRendering = $false
    $label.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 11
    $label.Location = New-Object System.Drawing.Point 14, 14
    $label.Text = Get-DetailText $state $now

    $panel.Controls.Add($label)
    $f.Controls.Add($panel)
    $f.ActiveControl = $null
    $script:DetailForm = $f
    $f.Show()
  } catch {
    Write-Log "detail window failed: $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
  }
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

  $miDetail.Add_Click({ Show-Detail $script:State (Get-Date) })
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

$script:State = $state
$script:IntervalSec = $IntervalSec

$script:SingleInstance = New-Object System.Threading.Mutex($false, 'Local\dsh-token-counter-singleton')
if (-not $script:SingleInstance.WaitOne(0)) { Write-Log 'another instance is already running, exiting'; exit 0 }

Start-Tray
