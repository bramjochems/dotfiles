#!/usr/bin/env bash
set -euo pipefail

echo "🔄 Updating package list..."
sudo apt update

echo "📦 Installing prerequisites..."
sudo apt install -y \
  curl \
  gpg

echo "🔑 Adding Microsoft GPG key and repository..."
curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-$(lsb_release -rs)-prod $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/dotnetdev.list

echo "🔄 Updating package list with new repository..."
sudo apt update

echo "⬇ Installing Azure Functions Core Tools..."
sudo apt install -y azure-functions-core-tools-4

echo "✅ Azure Functions Core Tools installed."
echo "🔍 Version check:"
func --version