#!/usr/bin/env bash
set -euo pipefail

# Configurable root (defaults to script dir)
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link() {
  local src="$DOTFILES_DIR/$1"
  local dest="$2"

  if [[ -L "$dest" || ! -e "$dest" ]]; then
    ln -sf "$src" "$dest"
    echo "✅ Linked $dest → $src"
  else
    echo "⚠️  Skipped $dest (already exists and is not a symlink)"
  fi
}

echo "🔗 Linking dotfiles..."

# Bash and shell files
link ".bashrc" "$HOME/.bashrc"
link ".bash_aliases" "$HOME/.bash_aliases"
link ".bash_profile" "$HOME/.bash_profile"
link ".tmux.conf" "$HOME/.tmux.conf"
link ".editorconfig" "$HOME/.editorconfig"
link "./scripts/bw-auto-auth.sh" "$HOME/.local/bin/bw-auto-auth"
link ".gitconfig" "$HOME:/.gitconfig"

# .config files and directories
mkdir -p "$HOME/.config"
link ".config/starship.toml" "$HOME/.config/starship.toml"
link ".config/dircolors" "$HOME/.config/dircolors"
link ".config/nvim" "$HOME/.config/nvim"

echo
echo "🚀 Running install scripts..."

# Neovim install
if [[ -x "$DOTFILES_DIR/install/neovim.sh" ]]; then
  "$DOTFILES_DIR/install/neovim.sh"
else
  echo "⚠️  Neovim install script not found or not executable"
fi

# Lazygit install
if [[ -x "$DOTFILES_DIR/install/lazygit.sh" ]]; then
  "$DOTFILES_DIR/install/lazygit.sh"
else
  echo "⚠️  Lazygit install script not found or not executable"
fi

# APT setup
if [[ -x "$DOTFILES_DIR/install/apt.sh" ]]; then
  "$DOTFILES_DIR/install/apt.sh"
fi

# Lazygit install
if [[ -x "$DOTFILES_DIR/install/bitwarden-cli.sh" ]]; then
  "$DOTFILES_DIR/install/bitwarden-cli.sh"
else
  echo "⚠️  Bitwarden cli install script not found or not executable"
fi

# Add more install scripts below
# "$DOTFILES_DIR/install/neovim.sh"
# "$DOTFILES_DIR/install/tmux.sh"

echo
echo "✅ Dotfiles setup complete."
