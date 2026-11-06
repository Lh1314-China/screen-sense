. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib.ps1")
$fail = 0
function Assert([bool]$c, [string]$n) { if ($c) { "PASS  $n" } else { "FAIL  $n"; $script:fail++ } }
Assert (Test-AppBlocked "KeePassXC") "blocked: KeepassXC"
Assert (Test-AppBlocked "1password") "blocked: 1password"
Assert (-not (Test-AppBlocked "chrome")) "allowed: chrome"
Assert (-not (Test-AppBlocked "")) "allowed: empty"
$fakePw = [pscustomobject]@{ Current = [pscustomobject]@{ IsPassword = $true } }
Assert ((Get-SafeFocusValue $fakePw "hunter2") -eq "[password]") "password value masked"
$fakePlain = [pscustomobject]@{ Current = [pscustomobject]@{ IsPassword = $false } }
Assert ((Get-SafeFocusValue $fakePlain "hello") -eq "hello") "plain value kept"
Assert ((Get-RedactedState "keepass").app -eq "[blocked]") "redacted state hides app"
if ($fail -gt 0) { "RESULT: $fail failed"; exit 1 } else { "RESULT: all passed" }

