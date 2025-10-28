#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing Codex CLI..."

npm install -g @openai/codex

echo "✅ Codex CLI installed. Version:"
codex --version
