# One-liner entry: irm <url>/run.ps1 | iex
# Downloads WinBoost.ps1 and runs it as admin; it copies itself to Program Files (admin-only) for the undo and report steps.
$f = "$env:TEMP\WinBoost.ps1"
Invoke-RestMethod 'https://faisalmt3.github.io/winboost/WinBoost.ps1' -OutFile $f
Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$f`"" -Verb RunAs
