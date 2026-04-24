#!/usr/bin/env bash
set -euo pipefail

FLAKE="flake.nix"
FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# Replace current hash with fake to force nix to reveal the correct one
sed -i.bak "s|outputHash = \"sha256-.*\";|outputHash = \"${FAKE_HASH}\";|" "$FLAKE"
rm -f "${FLAKE}.bak"

echo "Probing for correct node_modules hash..."
NIX_OUT=$(nix build 2>&1 || true)

REAL_HASH=$(echo "$NIX_OUT" | grep "got:" | awk '{print $2}')

if [[ -z "$REAL_HASH" ]]; then
  # No hash mismatch error — either build succeeded or failed for another reason
  if echo "$NIX_OUT" | grep -q "error:"; then
    echo "Build failed:"
    echo "$NIX_OUT"
    git checkout -- "$FLAKE" 2>/dev/null || true
    exit 1
  else
    echo "Hash was already correct. Build succeeded."
    echo "Done. Binary available at ./result/bin/realtime-check"
    exit 0
  fi
fi

echo "Updating hash to: $REAL_HASH"
sed -i.bak "s|outputHash = \"${FAKE_HASH}\";|outputHash = \"${REAL_HASH}\";|" "$FLAKE"
rm -f "${FLAKE}.bak"

echo "Building with correct hash..."
nix build
echo "Done. Binary available at ./result/bin/realtime-check"
