#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing OpenCode.ai (SST)..."

npm install -g opencode

echo "✅ OpenCode CLI installed. Version:"
opencode --version
