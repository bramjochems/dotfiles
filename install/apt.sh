#!/usr/bin/env bash
set -euo pipefail

echo "Adding repository for git"
sudo add-apt-repository ppa:git-core/ppa

echo "🔄 Updating package list..."
sudo apt update

echo "⬆️  Upgrading installed packages..."
sudo apt upgrade -y

echo "📦 Installing packages..."
sudo apt install -y \
  git \
  jq \
  curl \
  ripgrep \
  fd-find \
  tmux \
  starship \
  fzf \
  rsync \
  gdu \
  git-delta \
  zstd \
  restic

# Symlink fd -> fdfind if not already present
if ! command -v fd >/dev/null 2>&1; then
  echo "🔗 Creating symlink: fd → fdfind"
  ln -s "$(which fdfind)" "$HOME/.local/bin/fd"
else
  echo "✅ fd already available"
fi

echo "🔁 Unattended upgrades: also -updates and third-party repos"
sudo install -m 0644 "$(dirname "$0")/51unattended-upgrades-local" /etc/apt/apt.conf.d/51unattended-upgrades-local

echo "✅ APT packages installed."
