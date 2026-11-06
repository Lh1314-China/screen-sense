<#
  一键安装 + 启动

    powershell -ExecutionPolicy Bypass -File install.ps1              # 装到 DSH 技能目录并启动
    powershell -ExecutionPolicy Bypass -File install.ps1 -NoSkill     # 只启动，不装技能
    powershell -ExecutionPolicy Bypass -File install.ps1 -Status
    powershell -ExecutionPolicy Bypass -File install.ps1 -Stop
#>
param(
    [switch]$NoSkill,
    [switch]$Status,
    [switch]$Stop,
    [int]$Port = 8791,
    [string]$SkillDir = "$env:USERPROFILE\.dsh\skills"
)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot

function Test-Port([int]$p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync("127.0.0.1", $p).Wait(500)
        $c.Close()
        return $ok
    } catch { return $false }
}

function Get-ActualPort {
    $f = Join-Path $Here "port.txt"
    if (Test-Path $f) {
        $v = (Get-Content $f -Raw).Trim()
        if ($v -match '^\d+$') { return [int]$v }
    }
    return $Port
}

if ($Status) {
    $Port = Get-ActualPort
    Write-Host ("screen-sense  ({0}): {1}" -f $Port, $(if ($up) { "在线" } else { "离线" }))
    if ($up) {
        # 有 python 就顺手打一条摘要；没有就跳过，不算错误
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) {
            try { & $py.Source (Join-Path $Here "query.py") digest | Select-Object -First 3 } catch { }
        }
    }
    exit 0
}

if ($Stop) {
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Write-Host "已停止"
    exit 0
}

if (-not $NoSkill) {
    $target = Join-Path $SkillDir "dsh-screen-sense"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $Here "SKILL.md") (Join-Path $target "SKILL.md") -Force
    Write-Host "技能已安装：$target"
}

if (Test-Port $Port) {
    Write-Host "服务已在运行（端口 $Port）"
} else {
    $p = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Here "daemon.ps1"), "-Port", "$Port") `
        -WindowStyle Hidden -PassThru
    Write-Host "已启动守护进程 (pid $($p.Id))"
    Start-Sleep -Seconds 3
    Write-Host ("端口 {0}：{1}" -f $Port, $(if (Test-Port $Port) { "在线" } else { "启动失败" }))
}

Write-Host ""
Write-Host "试用： python query.py digest"
Write-Host "事件： python query.py events"


