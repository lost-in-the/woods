#!/usr/bin/env bash
set -euo pipefail

# Build Liam ERD frontend assets for vendoring in the Woods gem.
#
# Prerequisites: Node.js >= 18, pnpm >= 10
#
# Usage: ./scripts/build-liam-erd.sh
#
# This clones the Liam ERD repository, builds the CLI frontend package,
# and copies the compiled assets to vendor/assets/liam-erd/.

LIAM_VERSION="@liam-hq/cli@0.7.9"  # Pin to a specific release
LIAM_REPO="https://github.com/liam-hq/liam.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$ROOT_DIR/vendor/assets/liam-erd"
TEMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "==> Cloning Liam ERD at $LIAM_VERSION..."
git clone --depth 1 --branch "$LIAM_VERSION" "$LIAM_REPO" "$TEMP_DIR/liam" 2>/dev/null || {
  echo "Tag $LIAM_VERSION not found, cloning main and checking out..."
  git clone --depth 100 "$LIAM_REPO" "$TEMP_DIR/liam"
  cd "$TEMP_DIR/liam"
  git checkout "$LIAM_VERSION"
}

cd "$TEMP_DIR/liam"

echo "==> Installing dependencies..."
pnpm install --frozen-lockfile

echo "==> Building CLI frontend..."
export VITE_CLI_VERSION_VERSION="woods-embedded"
export VITE_CLI_VERSION_GIT_HASH="$(git rev-parse --short HEAD)"
export VITE_CLI_VERSION_ENV_NAME="woods"
export VITE_CLI_VERSION_IS_RELEASED_GIT_HASH="0"
export VITE_CLI_VERSION_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the CLI package and its workspace dependencies using turbo.
# turbo resolves the dependency graph automatically (schema -> erd-core -> cli).
pnpm turbo run build --filter=@liam-hq/cli

echo "==> Copying built assets to $VENDOR_DIR..."
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
cp -r frontend/packages/cli/dist-cli/html/* "$VENDOR_DIR/"

# Remove schema.json and serve.json if present (we generate schema dynamically)
rm -f "$VENDOR_DIR/schema.json" "$VENDOR_DIR/serve.json"

LIAM_HASH=$(git rev-parse --short HEAD)
echo "==> Done! Assets vendored at $VENDOR_DIR"
echo "    Liam version: $LIAM_VERSION"
echo "    Git hash: $LIAM_HASH"
ls -lah "$VENDOR_DIR/"
