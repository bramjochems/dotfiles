#!/usr/bin/env bash
set -euo pipefail

echo "Installing Rust via rustup..."

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Add cargo to PATH for current session
source "$HOME/.cargo/env"

echo "Rust installed. Version:"
rustc --version
cargo --version

echo ""
echo "Note: You may need to restart your shell or run:"
echo "   source \$HOME/.cargo/env"
echo "   to ensure cargo and rustc are in your PATH."
