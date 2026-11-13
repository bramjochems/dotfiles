# Windows apps

`winget.json` lists the Windows apps on the laptop (user-facing apps only;
runtimes such as .NET and VC++ come in as dependencies). On a new machine,
in PowerShell:

```powershell
winget import -i <dotfiles>\windows\winget.json --accept-package-agreements --accept-source-agreements
```

(`<dotfiles>` = this repo, e.g. `\\wsl.localhost\Ubuntu\home\<user>\dotfiles`). Install Office from the Microsoft 365
portal and WSL with `wsl --install` first; then run `install.sh` inside WSL.

Add or drop an app: `winget install <id>` / `winget uninstall <id>` and
update this list (`winget search <name>` gives the id). Not in the list on
purpose: Lenovo/NVIDIA hardware tools, Office/Teams/OneDrive/Edge (come
with Office/Windows), runtimes.
