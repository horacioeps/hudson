#!/usr/bin/env bash
# Signs the hudson CLI with a stable identity so Keychain ACLs survive
# rebuilds (spec §6.3). Without this, every `swift build` produces a
# different ad-hoc identity and the Keychain re-prompts on each run.
set -euo pipefail

BINARY="${1:-.build/debug/hudson}"
IDENTITY="${HUDSON_SIGN_IDENTITY:-hudson-dev}"

if [[ ! -f "$BINARY" ]]; then
    echo "error: $BINARY not found — run 'swift build' first" >&2
    exit 1
fi

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$BINARY"
    echo "Signed $BINARY with '$IDENTITY'."
else
    codesign --force --sign - "$BINARY"
    cat >&2 <<'EOF'
warning: no 'hudson-dev' code-signing identity found; used ad-hoc signing.
The Keychain will re-prompt after every rebuild. To fix (one time):
  Keychain Access → Certificate Assistant → Create a Certificate…
  Name: hudson-dev · Identity type: Self-Signed Root · Certificate type: Code Signing
Then re-run this script.
EOF
fi
