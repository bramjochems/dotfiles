#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing Claude Code..."

npm install -g claude-code

echo "✅ Claude Code installed. Version:"
claude --version
