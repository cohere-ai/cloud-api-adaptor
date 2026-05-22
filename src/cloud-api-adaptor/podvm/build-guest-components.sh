#!/bin/bash
# Build selected guest-components binaries from source.
#
# Usage: build-guest-components.sh <comma-separated-binaries> [aa-features]
#
# Recognized binaries:
#   attestation-agent       — requires aa-features argument
#   api-server-rest
#   confidential-data-hub
#
# Source must already be cloned at /build/gc.
# Compiled binaries are placed in /output/.
# Runtime libraries needed by custom binaries are placed in /output/lib/.

set -euo pipefail

BINARIES="${1:-}"
AA_FEATURES="${2:-}"
OUTDIR="/output"
mkdir -p "$OUTDIR"

[ -z "$BINARIES" ] && exit 0

IFS=',' read -ra BINS <<< "$BINARIES"
for bin in "${BINS[@]}"; do
  bin=$(echo "$bin" | xargs)  # trim whitespace
  case "$bin" in
    attestation-agent)
      if [ -z "$AA_FEATURES" ]; then
        echo "ERROR: attestation-agent requires AA_FEATURES" >&2
        exit 1
      fi
      cd /build/gc/attestation-agent/attestation-agent
      cargo build --release --locked --no-default-features \
        --features "$AA_FEATURES" --bin ttrpc-aa
      cp /build/gc/target/release/ttrpc-aa "$OUTDIR/attestation-agent"
      ;;
    api-server-rest)
      cd /build/gc/api-server-rest
      cargo build --release --locked
      cp /build/gc/target/release/api-server-rest "$OUTDIR/api-server-rest"
      ;;
    confidential-data-hub)
      cd /build/gc/confidential-data-hub
      cargo build --release --locked
      cp /build/gc/target/release/confidential-data-hub "$OUTDIR/confidential-data-hub"
      ;;
    *)
      echo "ERROR: Unknown guest component: $bin" >&2
      echo "Recognized: attestation-agent, api-server-rest, confidential-data-hub" >&2
      exit 1
      ;;
  esac
  echo "Built: $bin"
done

if [[ "$AA_FEATURES" == *"nvidia-attester"* ]]; then
  mkdir -p "$OUTDIR/lib"
  find /usr/lib /usr/lib64 -maxdepth 3 -name 'libnvat.so*' \
    -exec cp -a {} "$OUTDIR/lib/" \; 2>/dev/null || true
  if ! compgen -G "$OUTDIR/lib/libnvat.so*" >/dev/null; then
    echo "ERROR: nvidia-attester was built but libnvat.so was not found" >&2
    exit 1
  fi
fi
