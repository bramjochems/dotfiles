#!/usr/bin/env bash
set -euo pipefail

# PowerShell 7 (pwsh) from Microsoft's Ubuntu repo, plus the Exchange Online
# module. pwsh is for Microsoft 365 admin (Exchange has no az-style CLI):
# mailbox permissions, Send As, distribution groups. Bash stays the shell.
# Sign in from WSL with: Connect-ExchangeOnline -UserPrincipalName <upn> -Device
# Upgrades: apt via unattended-upgrades (origin in 51unattended-upgrades-local);
# the module with: pwsh -c 'Update-PSResource ExchangeOnlineManagement -Repository PSGallery'
# -Repository PSGallery: pwsh 7.7 also searches MicrosoftArtifactRegistry, which
# answers "package: Not Found" for gallery modules.

source /etc/os-release
KEYRING=/usr/share/keyrings/microsoft-prod.gpg

echo "📦 Installing PowerShell..."

echo "🔑 Adding Microsoft GPG key..."
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
  sudo gpg --dearmor --yes -o "$KEYRING"
sudo chmod go+r "$KEYRING"

echo "📝 Adding Microsoft prod apt repository (Ubuntu $VERSION_ID)..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEYRING] https://packages.microsoft.com/ubuntu/$VERSION_ID/prod $VERSION_CODENAME main" | \
  sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null

echo "🔄 Updating package list..."
sudo apt update

echo "⬇️  Installing PowerShell..."
sudo apt install -y powershell

echo "⬇️  Installing ExchangeOnlineManagement module (current user)..."
pwsh -NoProfile -Command '
  $ErrorActionPreference = "Stop"
  if (Get-PSResource -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue) {
    Update-PSResource -Name ExchangeOnlineManagement -Repository PSGallery -TrustRepository
  } else {
    Install-PSResource -Name ExchangeOnlineManagement -Repository PSGallery -Scope CurrentUser -TrustRepository
  }
'

echo "✅ PowerShell installed. Versions:"
pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString(); (Get-PSResource ExchangeOnlineManagement | Select-Object -First 1).Version.ToString()'
