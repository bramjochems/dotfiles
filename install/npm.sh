#!/usr/bin/env bash
set -euo pipefail

echo "🔄 Updating package list..."
sudo apt update

echo "⬆️  Upgrading installed packages..."
sudo apt upgrade -y

echo "📦 Installing packages..."
sudo apt install -y \
  npm

echo "✅ NPM installed."
