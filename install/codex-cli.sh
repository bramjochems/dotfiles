#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing Codex CLI..."

npm install -g codex-cli

echo "✅ Codex CLI installed. Version:"
codex --version
