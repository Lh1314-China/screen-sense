# Unit tests for the screen-sense helpers. No desktop interaction needed.
$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib.ps1")

$fail = 0
function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Output "PASS  $name" } else { Write-Output "FAIL  $name"; $script:fail++ }
}

# --- change key ---
$a = [pscustomobject]@{ app = "chromium"; title = "A"; focus = [pscustomobject]@{ role = "Window"; name = "A"; value = "" } }
$b = [pscustomobject]@{ app = "chromium"; title = "B"; focus = [pscustomobject]@{ role = "Window"; name = "A"; value = "" } }
$c = [pscustomobject]@{ app = "chromium"; title = "A"; focus = [pscustomobject]@{ role = "Edit"; name = "搜索"; value = "vrm" } }
$d = [pscustomobject]@{ app = "chromium"; title = "A"; focus = [pscustomobject]@{ role = "Window"; name = "A"; value = "" } }

Assert ((Get-StateKey $a) -eq (Get-StateKey $d)) "same state -> same key (no event)"
Assert ((Get-StateKey $a) -ne (Get-StateKey $b)) "title change -> new key"
Assert ((Get-StateKey $a) -ne (Get-StateKey $c)) "focus change -> new key"
Assert ((Get-StateKey ([pscustomobject]@{ app = "x"; title = "y"; focus = $null })) -eq "x|y|") "null focus is safe"

# --- token estimate ---
$t = Get-TokenEst '{"app":"chromium","title":"中文标题"}'
Assert ($t -gt 0 -and $t -lt 40) "token estimate in sane range ($t)"

# --- compression respects the budget ---
$big = [ordered]@{
    app   = "chromium"
    title = ("很长的标题" * 12)
    focus = [ordered]@{ role = "Edit"; name = "输入框"; value = ("内容" * 40); pos = @(0.5, 0.5) }
    wins  = @("窗口一", "窗口二", "窗口三", "窗口四", "窗口五", "窗口六")
}
$r1 = Compress-Digest $big 220
$r2 = Compress-Digest $big 60
$r3 = Compress-Digest $big 25
Assert ($r1.tokens -le 220) "fits budget 220 (got $($r1.tokens))"
Assert ($r2.tokens -le 60) "fits budget 60 (got $($r2.tokens))"
Assert ($r1.tokens -ge $r2.tokens) "smaller budget -> smaller digest"
Write-Output "budget 220 -> $($r1.tokens) tokens, keys: $($r1.data.Keys -join ',')"
Write-Output "budget  60 -> $($r2.tokens) tokens, keys: $($r2.data.Keys -join ',')"
Write-Output "budget  25 -> $($r3.tokens) tokens, keys: $($r3.data.Keys -join ',')"

if ($fail -gt 0) { Write-Output "RESULT: $fail failed"; exit 1 } else { Write-Output "RESULT: all passed"; exit 0 }

