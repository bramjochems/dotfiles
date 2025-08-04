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
  rsync

# Symlink fd -> fdfind if not already present
if ! command -v fd >/dev/null 2>&1; then
  echo "🔗 Creating symlink: fd → fdfind"
  ln -s "$(which fdfind)" "$HOME/.local/bin/fd"
else
  echo "✅ fd already available"
fi

echo "✅ APT packages installed."
