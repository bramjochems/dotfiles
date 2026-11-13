# Nightly job: upgrade everything winget manages, log to autoupgrade.log next to
# this script. Installed and scheduled by register-autoupgrade.ps1.
# Keep an app out of it with: winget pin add --id <id>
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'autoupgrade.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }

"=== $(Get-Date -Format s) ===" | Out-File $log -Append -Encoding utf8
winget upgrade --all --silent --disable-interactivity `
  --accept-package-agreements --accept-source-agreements 2>&1 |
  Where-Object { $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '█|▒' } |
  Out-File $log -Append -Encoding utf8
"exit code $LASTEXITCODE" | Out-File $log -Append -Encoding utf8
