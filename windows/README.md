# Windows apps

`winget.json` lists the Windows apps on the laptop (user-facing apps only;
runtimes such as .NET and VC++ come in as dependencies).

On a brand-new machine (no WSL, no git yet), in an admin PowerShell:

```powershell
iwr https://raw.githubusercontent.com/bramjochems/dotfiles/main/windows/winget.json -OutFile $env:TEMP\winget.json
winget import -i $env:TEMP\winget.json --accept-package-agreements --accept-source-agreements
```

With the repo already cloned:

```powershell
winget import -i <dotfiles>\windows\winget.json --accept-package-agreements --accept-source-agreements
```

(`<dotfiles>` = this repo, e.g. `\\wsl.localhost\Ubuntu\home\<user>\dotfiles`). Install Office from the Microsoft 365
portal and WSL with `wsl --install` first; then run `install.sh` inside WSL.

Add or drop an app: `winget install <id>` / `winget uninstall <id>` and
update this list (`winget search <name>` gives the id). Not in the list on
purpose: Lenovo/NVIDIA hardware tools, Office/Teams/OneDrive/Edge (come
with Office/Windows), runtimes.

## Scheduled upgrades

`register-autoupgrade.ps1` (admin PowerShell) schedules two elevated tasks, not
on battery. A missed run (laptop asleep or off) is skipped, not caught up later.

- **Daily 05:00**: `winget upgrade --all`, except the session-killing packages
  listed in `$SessionKillers` in `winget-autoupgrade.ps1` (WSL, Windows
  Terminal, Docker Desktop, VS Code, Ubuntu). Upgrading those restarts WSL or
  closes the window holding it, killing running shells and agents; the script
  pins them so `--all` skips them.
- **Monday 02:00** (Sunday night): upgrades only those pinned packages.

Log: `%LOCALAPPDATA%\winget-autoupgrade\autoupgrade.log`. Keep another app out
of the daily run with `winget pin add --id <id>`; to move one into the weekly
group, add it to `$SessionKillers` and re-run the register script.
