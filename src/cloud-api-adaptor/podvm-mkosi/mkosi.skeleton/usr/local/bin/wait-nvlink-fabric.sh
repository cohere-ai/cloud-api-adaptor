#!/bin/bash
# wait-nvlink-fabric.sh — block until NVML reports the NVLink fabric
# registration is COMPLETE on every visible GPU.
#
# Why this exists (HGX B200 + CC/NVLE):
#   On B200 in confidential-compute mode, the Service VM Fabric Manager
#   programs NVSwitch routing for a partition asynchronously. The handshake
#   with the guest GPU happens over in-band NVLink MAD (Probe Request ->
#   Probe Response) AFTER fmActivateFabricPartition() returns success.
#   nvidia-persistenced therefore races the handshake on guest boot. If it
#   registers a GPU before that GPU finishes its handshake, NVML returns
#   0x81 (NVLINK_FABRIC_NOT_READY) and the daemon silently falls back to
#   non-UVM persistence — leaving that GPU permanently unable to do NVLink
#   P2P. Per the NVIDIA Secure AI Operations Guide ("Ensure that
#   Persistence Mode is On"), the only way to recover from a missed
#   SPDM/UVM session in CC mode is an FLR, i.e. a full VM restart. So we
#   gate persistenced startup on fabric readiness rather than rely on the
#   daemons internal retry path (it does not retry on 0x81).
#
# This script is wired in via the nvidia-persistenced service drop-in
#   /usr/lib/systemd/system/nvidia-persistenced.service.d/override.conf
# as ExecStartPre. It exits non-zero on timeout so the daemon fails loud
# rather than silently degrading.

set -euo pipefail

TIMEOUT_SEC="${WAIT_FABRIC_TIMEOUT:-180}"
POLL_SEC="${WAIT_FABRIC_POLL:-2}"

log() { printf "[wait-nvlink-fabric] %s\n" "$*" >&2; }

deadline=$(( $(date +%s) + TIMEOUT_SEC ))
attempt=0

while :; do
    attempt=$((attempt+1))
    states=$(nvidia-smi --query-gpu=index,uuid,fabric.state,fabric.status \
                --format=csv,noheader 2>/dev/null || true)

    if [[ -z "$states" ]]; then
        log "attempt $attempt: nvidia-smi returned empty (driver not ready yet)"
    else
        not_ready=$(echo "$states" | awk -F"," "
            BEGIN { n = 0 }
            {
                gsub(/^ +| +\$/, \"\", \$3)
                gsub(/^ +| +\$/, \"\", \$4)
                if (\$3 != \"Completed\" || \$4 != \"Success\") n++
            }
            END { print n+0 }")

        if (( not_ready == 0 )); then
            log "all GPUs fabric ready (attempt $attempt)"
            echo "$states" | sed "s/^/[wait-nvlink-fabric]   /" >&2
            exit 0
        fi
        log "attempt $attempt: $not_ready GPU(s) fabric not yet Completed/Success"
    fi

    if (( $(date +%s) >= deadline )); then
        log "FAIL: NVLink fabric did not become ready within ${TIMEOUT_SEC}s"
        log "current per-GPU state:"
        echo "${states:-<empty>}" | sed "s/^/[wait-nvlink-fabric]   /" >&2
        exit 1
    fi

    sleep "$POLL_SEC"
done
