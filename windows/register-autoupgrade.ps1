#Requires -RunAsAdministrator
# Schedule winget-autoupgrade.ps1 daily at 02:00 for the current user, elevated
# (no UAC prompts). Only runs if the laptop is on and awake at 02:00: a missed
# run is skipped, never caught up the next morning. Not on battery. Re-run to update; remove with:
#   Unregister-ScheduledTask -TaskName 'winget auto-upgrade'
# Run from an admin PowerShell:
#   powershell -ExecutionPolicy Bypass -File <dotfiles>\windows\register-autoupgrade.ps1
$dest = Join-Path $env:LOCALAPPDATA 'winget-autoupgrade'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'winget-autoupgrade.ps1') $dest -Force   # local copy: works without WSL running

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\winget-autoupgrade.ps1`""
$trigger   = New-ScheduledTaskTrigger -Daily -At 2am
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName 'winget auto-upgrade' -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled 'winget auto-upgrade' daily at 02:00 (skipped when missed). Log: $dest\autoupgrade.log"
Write-Host "Test it now with: Start-ScheduledTask -TaskName 'winget auto-upgrade'"
