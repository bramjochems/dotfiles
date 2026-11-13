# Two-tier winget upgrades, logged to autoupgrade.log next to this script.
# Installed and scheduled by register-autoupgrade.ps1:
#   daily  (no args)  : upgrade everything EXCEPT $SessionKillers
#   weekly (-Weekly)  : upgrade only $SessionKillers
# Keep any other app out of the daily run with: winget pin add --id <id>
param([switch]$Weekly)

# Packages whose upgrade restarts WSL or closes the terminal / editor holding
# WSL sessions, killing running shells and agents. Kept out of the daily run
# with a winget pin (re-added each run, no-op if present). A plain pin skips
# them in `upgrade --all` but still allows an explicit upgrade by id.
$SessionKillers = @(
  'Microsoft.WSL'               # restarts the WSL VM
  'Microsoft.WindowsTerminal'   # closes all Terminal windows
  'Docker.DockerDesktop'        # restarts its WSL backend
  'Microsoft.VisualStudioCode'  # drops Remote-WSL sessions
  'Canonical.Ubuntu'            # the distro package itself
)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'autoupgrade.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }
function Write-Log { process { $_ | Out-File $log -Append -Encoding utf8 } }
function Filter-Progress { process { if ($_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '\u2588|\u2592') { $_ } } }
$common = @('--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')

if ($Weekly) {
  "=== $(Get-Date -Format s) weekly (session-killing packages) ===" | Write-Log
  foreach ($id in $SessionKillers) {
    "--- $id" | Write-Log
    winget upgrade --id $id --exact --include-pinned @common 2>&1 | Filter-Progress | Write-Log
    "exit code $LASTEXITCODE" | Write-Log
  }
} else {
  "=== $(Get-Date -Format s) daily ===" | Write-Log
  foreach ($id in $SessionKillers) { winget pin add --id $id --exact --disable-interactivity *> $null }
  winget upgrade --all @common 2>&1 | Filter-Progress | Write-Log
  "exit code $LASTEXITCODE" | Write-Log
}
