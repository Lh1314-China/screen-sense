# screen-sense shared helpers (dot-source this)

function Get-AppFromClass([string]$cls, [string]$procName) {
    if ($procName) { return $procName }
    if ($cls -like "*Chrome_WidgetWin*") { return "chromium" }
    if ($cls -eq "CabinetWClass") { return "explorer" }
    if ($cls -eq "MozillaWindowClass") { return "firefox" }
    if ($cls -eq "Notepad") { return "notepad" }
    if ($cls -like "HwndWrapper*") { return "wpf" }
    if ($cls -eq "ApplicationFrameWindow") { return "uwp" }
    return $cls
}

# The change key decides whether a new event is emitted. It must be cheap and
# must capture exactly the things a viewer would notice.
function Get-StateKey($state) {
    $focus = if ($state.focus) { "$($state.focus.role)|$($state.focus.name)|$($state.focus.value)" } else { "" }
    return "$($state.app)|$($state.title)|$focus"
}

# --- privacy guards -------------------------------------------------------
# Apps whose content must never leave the process.
$script:BlockedApps = @(
    "keepass", "keepassxc", "1password", "bitwarden", "lastpass",
    "authenticator", "securitykey"
)

function Test-AppBlocked([string]$app) {
    if (-not $app) { return $false }
    $a = $app.ToLowerInvariant()
    foreach ($b in $script:BlockedApps) {
        if ($a -eq $b -or $a -like "*$b*") { return $true }
    }
    return $false
}

# Password fields must never be read, even when the element exposes a value.
function Get-SafeFocusValue($element, [string]$rawValue) {
    if (-not $element) { return "" }
    try {
        if ($element.Current.IsPassword) { return "[password]" }
    } catch { }
    if ($rawValue) { return $rawValue }
    return ""
}

# Everything that touches a blocked app collapses to a single opaque label.
function Get-RedactedState([string]$app) {
    return [ordered]@{
        app   = "[blocked]"
        cls   = ""
        title = "($app)"
        focus = $null
        wins  = @()
    }
}

# --- capture retention ----------------------------------------------------
# 截图会落盘，所以只留最近 $script:CaptureKeep 张，其余立刻删掉。
$script:CaptureKeep = 20

function Clear-OldCaptures([string]$dir, [int]$keep = 0) {
    if (-not (Test-Path $dir)) { return 0 }
    $files = Get-ChildItem $dir -Filter *.png -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    # keep < 0 表示全删；keep = 0 用默认保留数
    $limit = if ($keep -lt 0) { 0 } elseif ($keep -gt 0) { $keep } else { $script:CaptureKeep }
    $removed = 0
    $files | Select-Object -Skip $limit | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        $removed++
    }
    return $removed
}

function Get-TokenEst([string]$json) {
    # mixed CJK/latin JSON: ~2.2 chars per token
    return [Math]::Round($json.Length / 2.2)
}

# Trim optional fields until the digest fits the budget.
function Compress-Digest($digest, [int]$budget) {
    $json = $digest | ConvertTo-Json -Depth 5 -Compress
    if ((Get-TokenEst $json) -le $budget) { return @{ data = $digest; json = $json; tokens = (Get-TokenEst $json) } }

    $trimmed = [ordered]@{}
    foreach ($k in $digest.Keys) { $trimmed[$k] = $digest[$k] }

    # 先只保留前 4 个窗口名，还超预算再整块丢掉
    if ($trimmed.Contains("wins") -and $trimmed["wins"].Count -gt 4) {
        $trimmed["wins"] = @($trimmed["wins"] | Select-Object -First 4)
        $json = $trimmed | ConvertTo-Json -Depth 5 -Compress
        if ((Get-TokenEst $json) -le $budget) { return @{ data = $trimmed; json = $json; tokens = (Get-TokenEst $json) } }
    }
    if ($trimmed.Contains("wins")) { $trimmed.Remove("wins") }
    $json = $trimmed | ConvertTo-Json -Depth 5 -Compress
    if ((Get-TokenEst $json) -le $budget) { return @{ data = $trimmed; json = $json; tokens = (Get-TokenEst $json) } }

    if ($trimmed.Contains("focus") -and $trimmed["focus"] -and $trimmed["focus"].Contains("value")) {
        $trimmed["focus"].Remove("value")
    }
    $json = $trimmed | ConvertTo-Json -Depth 5 -Compress
    if ((Get-TokenEst $json) -le $budget) { return @{ data = $trimmed; json = $json; tokens = (Get-TokenEst $json) } }

    if ($trimmed.Contains("focus") -and $trimmed["focus"] -and $trimmed["focus"].Contains("pos")) {
        $trimmed["focus"].Remove("pos")
    }
    $json = $trimmed | ConvertTo-Json -Depth 5 -Compress
    if ((Get-TokenEst $json) -le $budget) { return @{ data = $trimmed; json = $json; tokens = (Get-TokenEst $json) } }

    # hard caps: shrink remaining free text until the budget really holds
    if ($trimmed.Contains("focus") -and $trimmed["focus"] -and $trimmed["focus"].Contains("name")) {
        $n = $trimmed["focus"]["name"]
        if ($n -and $n.Length -gt 16) { $trimmed["focus"]["name"] = $n.Substring(0, 16) }
    }
    foreach ($cap in 40, 24, 12, 6) {
        $t = "$($trimmed["title"])"
        if ($t.Length -gt $cap) { $trimmed["title"] = $t.Substring(0, $cap) }
        $json = $trimmed | ConvertTo-Json -Depth 5 -Compress
        if ((Get-TokenEst $json) -le $budget) { return @{ data = $trimmed; json = $json; tokens = (Get-TokenEst $json) } }
    }
    if ($trimmed.Contains("focus")) { $trimmed.Remove("focus") }
    $json = $trimmed | ConvertTo-Json -Depth 5 -Compress
    return @{ data = $trimmed; json = $json; tokens = (Get-TokenEst $json) }
}

