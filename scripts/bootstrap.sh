#!/usr/bin/env bash
# Generate the Xcode project from mac/project.yml.
# Run this once after cloning, and any time you edit project.yml.
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Installing with Homebrew..."
  brew install xcodegen
fi

cd "$(dirname "$0")/../mac"
xcodegen generate
echo "✓ Generated mac/MiniEreader.xcodeproj — open it with: open mac/MiniEreader.xcodeproj"
