#!/usr/bin/env bash
set -euo pipefail

echo "🔄 Cleaning old Azure Functions Core Tools configuration..."
sudo rm -f /etc/apt/sources.list.d/azure-functions.list || true
sudo rm -f /etc/apt/sources.list.d/dotnetdev.list || true

echo "📦 Installing prerequisites..."
sudo apt update
sudo apt install -y curl npm

echo "⬇ Installing Azure Functions Core Tools (via npm)..."
sudo npm install -g azure-functions-core-tools@4 --unsafe-perm true

echo "✅ Azure Functions Core Tools installed."
echo "🔍 Version check:"
func --version
