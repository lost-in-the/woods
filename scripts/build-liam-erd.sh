#!/usr/bin/env bash
set -euo pipefail

# Build Liam ERD frontend assets from the local fork.
#
# Prerequisites: Node.js >= 18, pnpm >= 10
#
# Usage: ./scripts/build-liam-erd.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$ROOT_DIR/frontend/liam-erd"
VENDOR_DIR="$ROOT_DIR/vendor/assets/liam-erd"

if [ ! -d "$FRONTEND_DIR" ]; then
  echo "ERROR: frontend/liam-erd/ not found. Run from the woods-erd repo root."
  exit 1
fi

cd "$FRONTEND_DIR"

echo "==> Installing dependencies..."
pnpm install --frozen-lockfile 2>/dev/null || pnpm install

echo "==> Building CLI frontend..."
export VITE_CLI_VERSION_VERSION="woods-embedded-phase2"
export VITE_CLI_VERSION_GIT_HASH="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
export VITE_CLI_VERSION_ENV_NAME="woods"
export VITE_CLI_VERSION_IS_RELEASED_GIT_HASH="0"
export VITE_CLI_VERSION_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

pnpm build:vite

echo "==> Copying built assets to $VENDOR_DIR..."
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
cp -r packages/cli/dist-cli/html/* "$VENDOR_DIR/"

# Remove schema.json and serve.json if present (we generate schema dynamically)
rm -f "$VENDOR_DIR/schema.json" "$VENDOR_DIR/serve.json"

echo "==> Done! Assets vendored at $VENDOR_DIR"
ls -lah "$VENDOR_DIR/"
