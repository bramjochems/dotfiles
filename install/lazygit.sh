#!/usr/bin/env bash
set -e

echo "🔍 Checking latest Lazygit version..."
VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

if [[ -z "$VERSION" ]]; then
  echo "❌ Failed to fetch Lazygit version"
  exit 1
fi

echo "⬇ Downloading Lazygit v$VERSION..."
curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${VERSION}/lazygit_${VERSION}_Linux_x86_64.tar.gz"

echo "📦 Extracting..."
tar -xzf /tmp/lazygit.tar.gz -C /tmp

echo "🚀 Installing to /usr/local/bin..."
sudo install /tmp/lazygit /usr/local/bin

echo "✅ Lazygit v$VERSION installed."
