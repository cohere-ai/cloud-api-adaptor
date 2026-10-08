#!/usr/bin/env bash
# Asserts Cohere's single-provider chart defaults.
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

render() {
  local provider="$1"
  shift
  helm template peerpods "${CHART_DIR}" -f "${CHART_DIR}/providers/${provider}.yaml" "$@" >"${TMP}/${provider}.yaml"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# CAA container command: the first entry of the cloud-api-adaptor
# DaemonSet's command list.
caa_command() {
  awk '
    /^kind: DaemonSet/ { ds = 1 }
    ds && /^  name: cloud-api-adaptor-daemonset$/ { caa = 1 }
    caa && /- command:/ { getline; sub(/^[[:space:]]*- /, ""); print; exit }
  ' "$1"
}

# genpolicy 4.x only generates emptyDir rules for
# disable_guest_empty_dir = true (kata-containers #12373), but the Go
# runtime's configuration-remote.toml still hard-codes false. Without this
# drop-in every peer pod with an emptyDir is rejected by its generated policy.
render gcp
grep -qE '^  dropin-remote\.toml: \|' "${TMP}/gcp.yaml" ||
  fail "kata-deploy renders no drop-in for the remote shim"
grep -qE '^    disable_guest_empty_dir = true$' "${TMP}/gcp.yaml" ||
  fail "remote shim drop-in does not set disable_guest_empty_dir = true"

# GCP runs cloud-api-adaptor directly: entrypoint.sh requires
# GCP_CREDENTIALS, which is empty with Workload Identity. Every other
# provider keeps upstream's entrypoint.sh.
grep -qE '^        - exec cloud-api-adaptor gcp$' "${TMP}/gcp.yaml" ||
  fail "gcp CAA does not exec cloud-api-adaptor gcp"
for provider in azure aws libvirt; do
  render "${provider}"
  cmd="$(caa_command "${TMP}/${provider}.yaml")"
  [[ "${cmd}" == "/usr/local/bin/entrypoint.sh" ]] ||
    fail "${provider} CAA command is '${cmd}', want /usr/local/bin/entrypoint.sh"
done
render azure --set 'command={/bin/sh,-c,exec cloud-api-adaptor azure}'
grep -qE '^        - exec cloud-api-adaptor azure$' "${TMP}/azure.yaml" ||
  fail "explicit command is not honoured"

# The GKE node fix patches GKE-only paths and restarts kubelet. By default
# it only renders when the provider is gcp; an explicit value wins.
has_gke_fix() { grep -qE '^  name: fix-gke-node-config$' "$1"; }
render gcp
has_gke_fix "${TMP}/gcp.yaml" || fail "gcp does not render fix-gke-node-config by default"
render gcp --set gkeNodeFix.enabled=false
has_gke_fix "${TMP}/gcp.yaml" && fail "gkeNodeFix.enabled=false still renders fix-gke-node-config"
render azure
has_gke_fix "${TMP}/azure.yaml" && fail "azure renders fix-gke-node-config by default"
render azure --set gkeNodeFix.enabled=true
has_gke_fix "${TMP}/azure.yaml" || fail "gkeNodeFix.enabled=true does not render fix-gke-node-config"

echo "chart default checks passed"
