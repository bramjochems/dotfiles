#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing Julia Programming Language..."

# Install Julia using juliaup (official Julia version manager)
echo "⬇️  Installing juliaup (Julia version manager)..."
curl -fsSL https://install.julialang.org | sh -s -- --yes

# Add juliaup to PATH for current session
export PATH="$HOME/.juliaup/bin:$PATH"

# Install the latest stable Julia version
echo "🔄 Installing latest stable Julia version..."
juliaup add release
juliaup default release

# Verify installation
echo "✅ Julia installed. Version:"
julia --version

echo ""
echo "📝 Note: You may need to restart your shell or run:"
echo "   source ~/.bashrc"
echo "   to ensure Julia is in your PATH."
