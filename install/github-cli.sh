#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing GitHub CLI..."

# Remove old configuration if it exists
echo "🔄 Cleaning old GitHub CLI configuration..."
sudo rm -f /etc/apt/sources.list.d/github-cli.list
sudo rm -f /usr/share/keyrings/githubcli-archive-keyring.gpg

# Add the GitHub CLI GPG key
echo "🔑 Adding GitHub CLI GPG key..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
  sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

# Add the GitHub CLI apt repository
echo "📝 Adding GitHub CLI apt repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
  sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

# Update and install
echo "🔄 Updating package list..."
sudo apt update

echo "⬇️  Installing GitHub CLI..."
sudo apt install -y gh

# Verify installation
echo "✅ GitHub CLI installed. Version:"
gh --version
