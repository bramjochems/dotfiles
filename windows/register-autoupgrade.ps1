#Requires -RunAsAdministrator
# Schedule winget-autoupgrade.ps1 for the current user, elevated (no UAC prompts):
#   'winget auto-upgrade'        daily 05:00   everything except session-killing packages
#   'winget auto-upgrade weekly' Monday 02:00  only WSL/Terminal/Docker/VS Code/Ubuntu
# Only runs if the laptop is on and awake at that time: a missed run is skipped,
# never caught up. Not on battery. Re-run to update; remove with:
#   Unregister-ScheduledTask -TaskName 'winget auto-upgrade'
#   Unregister-ScheduledTask -TaskName 'winget auto-upgrade weekly'
# Run from an admin PowerShell:
#   powershell -ExecutionPolicy Bypass -File <dotfiles>\windows\register-autoupgrade.ps1
$dest = Join-Path $env:LOCALAPPDATA 'winget-autoupgrade'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'winget-autoupgrade.ps1') $dest -Force   # local copy: works without WSL running

$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$script    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\winget-autoupgrade.ps1`""

$tasks = @(
  @{ Name = 'winget auto-upgrade';        Args = $script;            Trigger = New-ScheduledTaskTrigger -Daily -At 5am }
  @{ Name = 'winget auto-upgrade weekly'; Args = "$script -Weekly";  Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 2am }
)
foreach ($t in $tasks) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $t.Args
  Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $t.Trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
  Write-Host "Scheduled '$($t.Name)'"
}
Write-Host "Log: $dest\autoupgrade.log"
Write-Host "Test with: Start-ScheduledTask -TaskName 'winget auto-upgrade'  (or '... weekly')"
