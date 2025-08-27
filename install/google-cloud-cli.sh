#!/usr/bin/env bash
set -euo pipefail

echo "📦 Installing Google Cloud CLI..."

# Install prerequisites
echo "📋 Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates gnupg

# Add the Google Cloud CLI distribution URI as a package source
echo "🌐 Adding Google Cloud CLI package source..."
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list

# Import the Google Cloud public key
echo "🔑 Importing Google Cloud public key..."
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

# Update and install the Google Cloud CLI
echo "🔄 Updating package list..."
sudo apt-get update

echo "⬇️  Installing Google Cloud CLI..."
sudo apt-get install -y google-cloud-cli

# Verify installation
echo "✅ Google Cloud CLI installed. Version:"
gcloud version
