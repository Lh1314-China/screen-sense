<#
  dsh-screen-sense / daemon prototype (P0)
  - resident: polls UI Automation + Win32, keeps a change log
  - serves a newline-JSON protocol on 127.0.0.1:8791
  - never takes a screenshot
  - token budget enforced by Compress-Digest (lib.ps1)

  protocol (one JSON per line in, one JSON per line out):
    {"op":"ping"}
    {"op":"digest","budget":220}
    {"op":"events","since":0}
    {"op":"stop"}
#>
param(
    [int]$Port = 8791,
    [int]$PollMs = 250
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\cdp.ps1"

if (-not ("SS.Win32" -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace SS {
  public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  }
}
"@
}

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function Read-Foreground {
    $hwnd = [SS.Win32]::GetForegroundWindow()
    $r = New-Object SS.Win32+RECT
    [void][SS.Win32]::GetWindowRect($hwnd, [ref]$r)
    $w = [Math]::Max(1, $r.Right - $r.Left)
    $h = [Math]::Max(1, $r.Bottom - $r.Top)

    $sb = New-Object System.Text.StringBuilder 512
    [void][SS.Win32]::GetWindowText($hwnd, $sb, 512)
    $title = $sb.ToString()

    $cb = New-Object System.Text.StringBuilder 256
    [void][SS.Win32]::GetClassName($hwnd, $cb, 256)
    $cls = $cb.ToString()

    $procId = [uint32]0
    [void][SS.Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $procName = ""
    try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }

    $focus = $null
    try {
        $fe = $AE::FocusedElement
        if ($fe) {
            $role = $fe.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $fname = $fe.Current.Name
            $fval = ""
            try {
                $vp = $fe.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                if ($vp) { $fval = $vp.Current.Value }
            } catch { }
            $fb = $fe.Current.BoundingRectangle
            $focus = [ordered]@{
                role  = $role
                name  = if ($fname) { $fname.Substring(0, [Math]::Min(40, $fname.Length)) } else { "" }
                value = (Get-SafeFocusValue $fe $fval)
                pos   = @([Math]::Round($fb.X / $w, 2), [Math]::Round($fb.Y / $h, 2))
            }
            if ($focus.value.Length -gt 80) { $focus.value = $focus.value.Substring(0, 80) }
        }
    } catch { }

    $app = Get-AppFromClass $cls $procName
    if (Test-AppBlocked $app) { return Get-RedactedState $app }

    [ordered]@{
        app   = $app
        cls   = $cls
        title = if ($title.Length -gt 64) { $title.Substring(0, 64) } else { $title }
        focus = $focus
    }
}

function Get-ScreenRegion {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [double]$Scale = 0.5)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $bmp = New-Object System.Drawing.Bitmap($W, $H)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
        $g.Dispose()

        $tw = [Math]::Max(1, [int]($W * $Scale))
        $th = [Math]::Max(1, [int]($H * $Scale))
        $small = New-Object System.Drawing.Bitmap($tw, $th)
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($bmp, 0, 0, $tw, $th)
        $g2.Dispose()
        $bmp.Dispose()

        $dir = Join-Path $PSScriptRoot "captures"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $file = Join-Path $dir ("cap_" + [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss_fff") + ".png")
        $small.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        $small.Dispose()
        [void](Clear-OldCaptures $dir)
        return [pscustomobject]@{ file = $file; w = $tw; h = $th; bytes = (Get-Item $file).Length }
    } catch {
        return $null
    }
}

function Read-Windows {
    $out = @()
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
        $all = $AE::RootElement.FindAll($TS::Children, $cond)
        foreach ($el in $all) {
            $n = $el.Current.Name
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($n.Length -gt 32) { $n = $n.Substring(0, 32) }
            $out += $n
            if ($out.Count -ge 10) { break }
        }
    } catch { }
    return $out
}

# ---------------- state ----------------
$winsCache = @()
$lastKey = $null
$seq = 0
$events = New-Object System.Collections.ArrayList
$started = Get-Date

$listener = $null
$boundPort = 0
for ($p = $Port; $p -lt ($Port + 10); $p++) {
    try {
        $cand = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $cand.Start()
        $listener = $cand
        $boundPort = $p
        break
    } catch { }
}
if (-not $listener) { Write-Error "端口 $Port ~ $($Port + 9) 都被占用"; exit 1 }
try { Set-Content -Path (Join-Path $PSScriptRoot "port.txt") -Value $boundPort -Encoding ASCII } catch { }

$lastPoll = [datetime]::MinValue
$run = $true

while ($run) {
    if (((Get-Date) - $lastPoll).TotalMilliseconds -ge $PollMs) {
        $lastPoll = Get-Date
        $cur = Read-Foreground
        $winsCache = Read-Windows
        $key = Get-StateKey $cur
        if ($key -ne $lastKey) {
            $seq++
            $entry = [ordered]@{
                seq   = $seq
                ts    = [int]([datetimeoffset]::UtcNow.ToUnixTimeSeconds())
                app   = $cur.app
                title = $cur.title
                focus = if ($cur.focus) { "$($cur.focus.role):$($cur.focus.name)" } else { "" }
            }
            [void]$events.Add($entry)
            if ($events.Count -gt 60) { $events.RemoveAt(0) }
            $lastKey = $key
        }
    }

    if ($listener.Pending()) {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $enc = New-Object System.Text.UTF8Encoding($false)
        $reader = New-Object System.IO.StreamReader($stream, $enc)
        $writer = New-Object System.IO.StreamWriter($stream, $enc)
        $writer.AutoFlush = $true
        try {
            $line = $reader.ReadLine()
            if ($line) {
                $req = $line | ConvertFrom-Json
                $resp = $null
                switch ($req.op) {
                    "ping" {
                        $resp = [ordered]@{ ok = $true; version = "0.2.0"; up_s = [int]((Get-Date) - $started).TotalSeconds; seq = $seq }
                    }
                    "region" {
                        # 按需升级：只有调用方明确要求时才截一块屏幕，默认永不自动触发
                        $x = [int]($req.x); $y = [int]($req.y)
                        $w = [int]($req.w); $h = [int]($req.h)
                        $scale = if ($req.scale) { [double]$req.scale } else { 0.5 }
                        if ($w -le 0 -or $h -le 0) {
                            $resp = [ordered]@{ ok = $false; error = "w/h must be > 0" }
                            break
                        }
                        $t0 = Get-Date
                        $shot = Get-ScreenRegion -X $x -Y $y -W $w -H $h -Scale $scale
                        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                        if ($shot) {
                            $resp = [ordered]@{
                                ok = $true; ms = $ms; file = $shot.file
                                w = $shot.w; h = $shot.h; bytes = $shot.bytes
                                token_est = [int][Math]::Round(($shot.w * $shot.h) / 750)
                            }
                        } else {
                            $resp = [ordered]@{ ok = $false; error = "capture failed" }
                        }
                    }
                    "screen" {
                        $scale = if ($req.scale) { [double]$req.scale } else { 0.5 }
                        $r = New-Object SS.Win32+RECT
                        [void][SS.Win32]::GetWindowRect([SS.Win32]::GetForegroundWindow(), [ref]$r)
                        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
                        $t0 = Get-Date
                        $shot = Get-ScreenRegion -X $vs.X -Y $vs.Y -W $vs.Width -H $vs.Height -Scale $scale
                        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                        if ($shot) {
                            $resp = [ordered]@{
                                ok = $true; ms = $ms; file = $shot.file
                                w = $shot.w; h = $shot.h; bytes = $shot.bytes
                                token_est = [int][Math]::Round(($shot.w * $shot.h) / 750)
                            }
                        } else {
                            $resp = [ordered]@{ ok = $false; error = "capture failed" }
                        }
                    }
                    "digest" {
                        $budget = if ($req.budget) { [int]$req.budget } else { 220 }
                        $t0 = Get-Date
                        $fg = Read-Foreground
                        $full = [ordered]@{
                            app   = $fg.app
                            title = $fg.title
                            focus = $fg.focus
                            wins  = $winsCache
                        }
                        $packed = Compress-Digest $full $budget
                        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                        $resp = [ordered]@{
                            ok     = $true
                            ms     = $ms
                            tokens = $packed.tokens
                            budget = $budget
                            digest = $packed.data
                        }
                    }
                    "pages" {
                        # browser tab list via DevTools HTTP endpoint (no websocket, no screenshot)
                        $cdpPort = if ($req.port) { [int]$req.port } else { 9222 }
                        $t0 = Get-Date
                        $pgs = @(Get-CdpPages -Port $cdpPort)
                        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
                        $resp = [ordered]@{ ok = $true; ms = $ms; count = $pgs.Count; pages = $pgs; error = $script:CdpLastError }
                    }
                    "captures" {
                        # 清理落盘截图：keep=-1 全删，不填则只留最近 20 张
                        $dir = Join-Path $PSScriptRoot "captures"
                        $keep = if ($null -ne $req.keep) { [int]$req.keep } else { -1 }
                        $removed = Clear-OldCaptures $dir $keep
                        $resp = [ordered]@{ ok = $true; removed = $removed }
                    }
                    "events" {                        $since = if ($null -ne $req.since) { [int]$req.since } else { 0 }
                        $resp = [ordered]@{ ok = $true; events = @($events | Where-Object { $_.seq -gt $since }) }
                    }
                    "stop" {
                        $resp = [ordered]@{ ok = $true; stopping = $true }
                        $run = $false
                    }
                    default { $resp = [ordered]@{ ok = $false; error = "unknown op" } }
                }
                $writer.WriteLine(($resp | ConvertTo-Json -Depth 6 -Compress))
            }
        } catch {
            try { $writer.WriteLine(([ordered]@{ ok = $false; error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress)) } catch { }
        } finally {
            $writer.Dispose(); $reader.Dispose(); $stream.Dispose(); $client.Close()
        }
    }

    Start-Sleep -Milliseconds 15
}

$listener.Stop()
Write-Output "daemon stopped"



