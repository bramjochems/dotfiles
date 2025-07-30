#!/usr/bin/env bash
set -e

echo "🔍 Checking latest Bitwarden CLI version..."
VERSION=$(curl -s https://api.github.com/repos/bitwarden/clients/releases/latest | grep '"tag_name":' | sed -E 's/.*"cli-v([^"]+)".*/\1/')
if [[ -z "$VERSION" ]]; then
  echo "❌ Failed to fetch Bitwarden CLI version"
  exit 1
fi

# Check if bw is already installed and get current version
if command -v bw &>/dev/null; then
  CURRENT_VERSION=$(bw --version 2>/dev/null | head -n1 || echo "unknown")
  echo "📋 Current version: $CURRENT_VERSION"
  echo "📋 Latest version: $VERSION"

  if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
    echo "✅ Bitwarden CLI is already up to date (v$VERSION)"
    exit 0
  fi

  echo "⬆️  Updating Bitwarden CLI from $CURRENT_VERSION to $VERSION..."
else
  echo "⬇️  Installing Bitwarden CLI v$VERSION..."
fi

echo "⬇️  Downloading Bitwarden CLI v$VERSION..."
curl -Lo /tmp/bw-linux.zip "https://github.com/bitwarden/clients/releases/download/cli-v${VERSION}/bw-linux-${VERSION}.zip"

echo "📦 Extracting..."
unzip -o /tmp/bw-linux.zip -d /tmp

echo "🚀 Installing to /usr/local/bin..."
sudo install /tmp/bw /usr/local/bin

echo "🧹 Cleaning up..."
rm -f /tmp/bw-linux.zip /tmp/bw

# Verify installation
if command -v bw &>/dev/null; then
  INSTALLED_VERSION=$(bw --version | head -n1)
  echo "✅ Bitwarden CLI v$INSTALLED_VERSION installed successfully!"

  echo ""
  echo "🔧 Next steps:"
  echo "   1. Configure your server: bw config server $BITWARDEN_SERVER_URL"
  echo "   2. Login to your vault: bw login"
  echo "   3. Test access: bw status"
else
  echo "❌ Installation failed - bw command not found"
  exit 1
fi
