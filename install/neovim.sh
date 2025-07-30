#!/usr/bin/env bash
set -euo pipefail

# Paths
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NVIM_BIN="/usr/local/bin/nvim"
NVIM_HOME="$HOME/.config/nvim"
NVIM_DOTFILES="$DOTFILES_DIR/.config/nvim"
LAZYVIM_STARTER_DIR="$DOTFILES_DIR/.config/nvim-upstream"
LAZYVIM_REPO="https://github.com/LazyVim/starter"
LAZYPATH="$HOME/.local/share/nvim/lazy/lazy.nvim"
TMP_DIR="$(mktemp -d)"

echo "⬇️ Installing Neovim (AppImage)..."
VERSION=$(curl -s https://api.github.com/repos/neovim/neovim/releases/latest | grep tag_name | cut -d '"' -f 4)
URL="https://github.com/neovim/neovim/releases/download/${VERSION}/nvim.appimage"
curl -Lo "$TMP_DIR/nvim.appimage" "$URL"
chmod +x "$TMP_DIR/nvim.appimage"
sudo mv "$TMP_DIR/nvim.appimage" "$NVIM_BIN"
rm -rf "$TMP_DIR"
echo "✅ Neovim installed: $($NVIM_BIN --version | head -n 1)"

echo "🔧 Installing dependencies..."
sudo apt install -y \
  ripgrep \
  fd-find \
  git \
  curl \
  unzip \
  build-essential \
  python3-pip \
  zenity

# Ensure fd is available as `fd`
if ! command -v fd >/dev/null 2>&1; then
  echo "🔗 Creating symlink: fd → fdfind"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(which fdfind)" "$HOME/.local/bin/fd"
fi

# Step 1: Pull/update LazyVim starter repo to a temporary folder
if [[ ! -d "$LAZYVIM_STARTER_DIR/.git" ]]; then
  echo "📦 Cloning LazyVim starter..."
  git clone "$LAZYVIM_REPO" "$LAZYVIM_STARTER_DIR"
else
  echo "🔁 Updating LazyVim starter..."
  git -C "$LAZYVIM_STARTER_DIR" pull --ff-only
fi

# Step 2: Sync upstream LazyVim changes into your dotfiles, EXCLUDING user/plugins
echo "🧩 Syncing LazyVim starter → $NVIM_DOTFILES (excluding your custom config)..."
rsync -a --delete \
  --exclude='.git' \
  --exclude='.gitignore' \
  --exclude='init.lua' \
  --exclude='lua/plugins/' \
  --exclude='lua/user/' \
  "$LAZYVIM_STARTER_DIR/" "$NVIM_DOTFILES/"

# Step 3: Ensure symlink ~/.config/nvim → dotfiles/.config/nvim
if [[ ! -L "$NVIM_HOME" ]]; then
  echo "🔗 Creating symlink: $NVIM_HOME → $NVIM_DOTFILES"
  rm -rf "$NVIM_HOME"
  ln -s "$NVIM_DOTFILES" "$NVIM_HOME"
else
  echo "✅ ~/.config/nvim is already symlinked"
fi

# Step 4: Bootstrap Lazy.nvim plugin manager (optional safety check)
if [[ ! -d "$LAZYPATH" ]]; then
  echo "📦 Installing Lazy.nvim plugin manager..."
  git clone --filter=blob:none https://github.com/folke/lazy.nvim.git --branch=stable "$LAZYPATH"
else
  echo "✅ Lazy.nvim already installed"
fi

# Step 5: Sync plugins
echo "📦 Syncing Lazy.nvim plugins..."
nvim --headless "+Lazy! sync" +qa

echo "✅ Neovim + LazyVim setup complete."
