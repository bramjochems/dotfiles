#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing AWS CLI v2..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "⬇️  Downloading..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$TMP_DIR/awscliv2.zip"

echo "📂 Extracting..."
unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"

# User-local install (no sudo); --update upgrades an existing install
echo "🚀 Installing to ~/.local/aws-cli..."
mkdir -p "$HOME/.local/bin"
"$TMP_DIR/aws/install" -i "$HOME/.local/aws-cli" -b "$HOME/.local/bin" --update

echo "✅ AWS CLI installed. Version:"
"$HOME/.local/bin/aws" --version
