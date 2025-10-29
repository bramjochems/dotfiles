#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing LaTeX environment..."

# Update package list
echo "🔄 Updating package list..."
sudo apt update

# Install TeX Live Full (includes latexmk)
echo "⬇️  Installing TeX Live Full (this may take a while)..."
sudo apt install -y texlive-full

# Install Zathura PDF viewer
echo "⬇️  Installing Zathura PDF viewer..."
sudo apt install -y zathura

# Install latexindent dependencies (Perl modules)
echo "⬇️  Installing latexindent dependencies..."
sudo apt install -y \
  libfile-homedir-perl \
  libyaml-tiny-perl \
  liblog-log4perl-perl \
  liblog-dispatch-perl

# Verify installations
echo ""
echo "✅ LaTeX environment installed successfully!"
echo ""
echo "📊 Installed versions:"
echo "  TeX Live: $(tex --version | head -n 1)"
echo "  LaTeXmk: $(latexmk -v | head -n 1)"
echo "  latexindent: $(latexindent -v | head -n 1)"
echo "  Zathura: $(zathura --version | head -n 1)"
