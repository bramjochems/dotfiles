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
link "./scripts/archive-project.sh" "$HOME/.local/bin/archive-project"
link "./scripts/wsl-backup.sh" "$HOME/.local/bin/wsl-backup"
link ".gitconfig" "$HOME/.gitconfig"
link ".gitignore_global" "$HOME/.gitignore_global"
link ".gitmessage" "$HOME/.gitmessage"

# .config files and directories
mkdir -p "$HOME/.config"
link ".config/starship.toml" "$HOME/.config/starship.toml"
link ".config/dircolors" "$HOME/.config/dircolors"
link ".config/nvim" "$HOME/.config/nvim"
mkdir -p "$HOME/.config/systemd/user"
link ".config/systemd/user/wsl-backup.service" "$HOME/.config/systemd/user/wsl-backup.service"
link ".config/systemd/user/wsl-backup.timer" "$HOME/.config/systemd/user/wsl-backup.timer"
# Enabling the timer is a manual step: it needs the restic password file
# (~/.config/restic-wsl/password, kept outside this repo) and an initialized
# repo first. Then: systemctl --user enable --now wsl-backup.timer

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

# Azure Functions Core Tools install
if [[ -x "$DOTFILES_DIR/install/azure-functions-core-tools.sh" ]]; then
  "$DOTFILES_DIR/install/azure-functions-core-tools.sh"
else
  echo "⚠️  Azure Functions Core Tools install script not found or not executable"
fi

# Google Cloud CLI install
if [[ -x "$DOTFILES_DIR/install/google-cloud-cli.sh" ]]; then
  "$DOTFILES_DIR/install/google-cloud-cli.sh"
else
  echo "⚠️  Google Cloud CLI install script not found or not executable"
fi

# AWS CLI install
if [[ -x "$DOTFILES_DIR/install/aws-cli.sh" ]]; then
  "$DOTFILES_DIR/install/aws-cli.sh"
else
  echo "⚠️  AWS CLI install script not found or not executable"
fi

# GitHub CLI install
if [[ -x "$DOTFILES_DIR/install/github-cli.sh" ]]; then
  "$DOTFILES_DIR/install/github-cli.sh"
else
  echo "⚠️  GitHub CLI install script not found or not executable"
fi

# Claude Code install
if [[ -x "$DOTFILES_DIR/install/claude-code.sh" ]]; then
  "$DOTFILES_DIR/install/claude-code.sh"
else
  echo "⚠️  Claude Code install script not found or not executable"
fi

# Codex CLI install
if [[ -x "$DOTFILES_DIR/install/codex-cli.sh" ]]; then
  "$DOTFILES_DIR/install/codex-cli.sh"
else
  echo "⚠️  Codex CLI install script not found or not executable"
fi

# OpenCode.ai (SST) install
if [[ -x "$DOTFILES_DIR/install/opencode-ai.sh" ]]; then
  "$DOTFILES_DIR/install/opencode-ai.sh"
else
  echo "⚠️  OpenCode.ai (SST) install script not found or not executable"
fi

# Rust install
if [[ -x "$DOTFILES_DIR/install/rust.sh" ]]; then
  "$DOTFILES_DIR/install/rust.sh"
else
  echo "⚠️  Rust install script not found or not executable"
fi

# LaTeX (texlive-full is several GB; used by pandoc md -> pdf/docx scripts)
if [[ -x "$DOTFILES_DIR/install/latex.sh" ]]; then
  "$DOTFILES_DIR/install/latex.sh"
else
  echo "⚠️  LaTeX install script not found or not executable"
fi

# Add more install scripts below
# "$DOTFILES_DIR/install/neovim.sh"
# "$DOTFILES_DIR/install/tmux.sh"

echo
echo "✅ Dotfiles setup complete."
