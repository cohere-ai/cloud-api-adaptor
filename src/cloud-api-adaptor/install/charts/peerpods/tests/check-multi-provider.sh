#!/usr/bin/env bash
# Static assertions for multi-provider peerpods chart rendering.
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${CHART_DIR}/tests/fixtures"
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

render() {
  local fixture="$1"
  local out="$2"
  helm template test-release "${CHART_DIR}" -f "${fixture}" "${@:3}" >"${out}"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -qE "${pattern}" "${file}"; then
    echo "FAIL: expected pattern not found: ${pattern}" >&2
    exit 1
  fi
}

assert_missing() {
  local file="$1"
  local pattern="$2"
  if grep -qE "${pattern}" "${file}"; then
    echo "FAIL: unexpected pattern found: ${pattern}" >&2
    exit 1
  fi
}

assert_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local actual
  actual="$(grep -cE "${pattern}" "${file}" || true)"
  if [[ "${actual}" -ne "${expected}" ]]; then
    echo "FAIL: expected ${expected} matches for ${pattern}, found ${actual}" >&2
    exit 1
  fi
}

echo "Rendering multi-provider-minimal.yaml..."
MINIMAL_OUT="${TMPDIR_ROOT}/minimal.yaml"
render "${FIXTURES}/multi-provider-minimal.yaml" "${MINIMAL_OUT}"
assert_contains "${MINIMAL_OUT}" 'name: cloud-api-adaptor-gcp'
assert_contains "${MINIMAL_OUT}" 'name: cloud-api-adaptor-azure'
assert_contains "${MINIMAL_OUT}" 'name: peer-pods-cm-gcp'
assert_contains "${MINIMAL_OUT}" 'name: peer-pods-cm-azure'
assert_contains "${MINIMAL_OUT}" 'name: kata-remote-gcp'
assert_contains "${MINIMAL_OUT}" 'name: kata-remote-azure'
assert_contains "${MINIMAL_OUT}" 'REMOTE_HYPERVISOR_ENDPOINT: "/run/peerpod/caa-gcp.sock"'
assert_contains "${MINIMAL_OUT}" 'POD_VM_EXTENDED_RESOURCE: "kata.peerpods.io/vm-gcp"'
assert_contains "${MINIMAL_OUT}" 'name: configure-remote-handlers'
assert_contains "${MINIMAL_OUT}" 'name: reconcile-remote-handlers'
assert_count "${MINIMAL_OUT}" 'failureThreshold: 90' 2
assert_contains "${MINIMAL_OUT}" 'VXLAN_PORT: "4789"'
assert_contains "${MINIMAL_OUT}" 'VXLAN_PORT: "4790"'
# Optional serviceAccount must not be required; no empty annotations key.
if awk '
  $0 ~ /^kind: ServiceAccount$/ { in_sa=1; next }
  in_sa && $0 ~ /^---$/ { in_sa=0 }
  in_sa && $0 ~ /^[[:space:]]*annotations:[[:space:]]*$/ { found=1 }
  END { exit found ? 0 : 1 }
' "${MINIMAL_OUT}"; then
  echo "FAIL: empty annotations block on ServiceAccount" >&2
  exit 1
fi
# Shared CM keeps identical PROXY_TIMEOUT from both providers.
assert_contains "${MINIMAL_OUT}" 'PROXY_TIMEOUT: "30m"'

echo "Rendering multi-provider-hybrid.yaml..."
HYBRID_OUT="${TMPDIR_ROOT}/hybrid.yaml"
render "${FIXTURES}/multi-provider-hybrid.yaml" "${HYBRID_OUT}"
assert_contains "${HYBRID_OUT}" 'name: cloud-api-adaptor-gcp-gcp-wif'
assert_contains "${HYBRID_OUT}" 'azure.workload.identity/client-id: 11111111-1111-1111-1111-111111111111'
assert_contains "${HYBRID_OUT}" 'azure.workload.identity/use: "true"'
assert_contains "${HYBRID_OUT}" 'GOOGLE_APPLICATION_CREDENTIALS'
assert_contains "${HYBRID_OUT}" 'ALLOWED_CLOUD_CONFIG_ANNOTATIONS: "io.katacontainers.config.hypervisor.gcp_zone,io.katacontainers.config.hypervisor.use_spot"'
assert_contains "${HYBRID_OUT}" 'kata-remote-gcp'
assert_contains "${HYBRID_OUT}" 'kata-remote-azure'
assert_contains "${HYBRID_OUT}" 'peer-pods-webhook-gcp-'
assert_contains "${HYBRID_OUT}" 'peer-pods-webhook-azure-'
assert_contains "${HYBRID_OUT}" 'name: fix-gke-node-config'
assert_contains "${HYBRID_OUT}" 'name: reconcile-remote-handlers'
assert_count "${HYBRID_OUT}" 'mountPath: /etc/certificates' 2
assert_count "${HYBRID_OUT}" 'secretName: certs-for-tls' 2
assert_contains "${HYBRID_OUT}" 'type: DirectoryOrCreate'
assert_contains "${HYBRID_OUT}" 'base remote config missing at \$BASE; retrying'
assert_contains "${HYBRID_OUT}" 'added \$DROPIN to multi-line containerd imports'
# Shared config is present in the controller and both provider ConfigMaps.
assert_count "${HYBRID_OUT}" 'PROXY_TIMEOUT: "30m"' 3
assert_count "${HYBRID_OUT}" 'DISABLECVM: "false"' 3
assert_count "${HYBRID_OUT}" 'CACERT_FILE: "/etc/certificates/ca.crt"' 3
# Empty imports = [] must be replaced, not rewritten to imports = [, "..."].
assert_contains "${HYBRID_OUT}" "imports = \\[[[:space:]]*\\]"
assert_contains "${HYBRID_OUT}" 'replaced empty containerd imports'

echo "Expecting duplicate probe port fixture to fail..."
if render "${FIXTURES}/multi-provider-duplicate-probe.yaml" "${TMPDIR_ROOT}/duplicate-probe.yaml" 2>"${TMPDIR_ROOT}/duplicate-probe.err"; then
  echo "FAIL: multi-provider-duplicate-probe.yaml rendered successfully" >&2
  exit 1
fi
if ! grep -Fq 'providers[].probePort must be unique' "${TMPDIR_ROOT}/duplicate-probe.err"; then
  echo "FAIL: expected duplicate probe port error, got:" >&2
  cat "${TMPDIR_ROOT}/duplicate-probe.err" >&2
  exit 1
fi

echo "Expecting duplicate VXLAN port configuration to fail..."
if render "${FIXTURES}/multi-provider-hybrid.yaml" "${TMPDIR_ROOT}/duplicate-vxlan.yaml" \
  --set 'providers[1].vxlanPort=4789' 2>"${TMPDIR_ROOT}/duplicate-vxlan.err"; then
  echo "FAIL: duplicate VXLAN ports rendered successfully" >&2
  exit 1
fi
if ! grep -Fq 'providers[].vxlanPort must be unique' "${TMPDIR_ROOT}/duplicate-vxlan.err"; then
  echo "FAIL: expected duplicate VXLAN port error, got:" >&2
  cat "${TMPDIR_ROOT}/duplicate-vxlan.err" >&2
  exit 1
fi

echo "Expecting managed ConfigMap key override to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/reserved-key.yaml" \
  --set 'sharedConfig.PROBE_PORT=9000' 2>"${TMPDIR_ROOT}/reserved-key.err"; then
  echo "FAIL: managed ConfigMap key override rendered successfully" >&2
  exit 1
fi
if ! grep -q 'sharedConfig.PROBE_PORT is managed by the chart' "${TMPDIR_ROOT}/reserved-key.err"; then
  echo "FAIL: expected managed ConfigMap key error, got:" >&2
  cat "${TMPDIR_ROOT}/reserved-key.err" >&2
  exit 1
fi

echo "Expecting conflict fixture to fail..."
if render "${FIXTURES}/multi-provider-conflict.yaml" "${TMPDIR_ROOT}/conflict.yaml" 2>"${TMPDIR_ROOT}/conflict.err"; then
  echo "FAIL: multi-provider-conflict.yaml rendered successfully" >&2
  exit 1
fi
if ! grep -q 'conflicts with' "${TMPDIR_ROOT}/conflict.err"; then
  echo "FAIL: expected conflict error, got:" >&2
  cat "${TMPDIR_ROOT}/conflict.err" >&2
  exit 1
fi

echo "Rendering multi-provider-disabled.yaml..."
DISABLED_OUT="${TMPDIR_ROOT}/disabled.yaml"
render "${FIXTURES}/multi-provider-disabled.yaml" "${DISABLED_OUT}"
assert_contains "${DISABLED_OUT}" 'name: cloud-api-adaptor-gcp'
assert_contains "${DISABLED_OUT}" 'name: kata-remote-gcp'
assert_missing "${DISABLED_OUT}" 'name: cloud-api-adaptor-azure'
assert_missing "${DISABLED_OUT}" 'name: peer-pods-cm-azure'
assert_missing "${DISABLED_OUT}" 'name: kata-remote-azure'

echo "Multi-provider chart checks passed"
