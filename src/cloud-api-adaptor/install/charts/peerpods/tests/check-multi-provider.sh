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

extract_remote_handler_script() {
  local rendered="$1"
  local script="$2"
  awk '
    /name: install-remote-handlers/ { in_container=1 }
    in_container && /- \|/ { in_block=1; next }
    in_block && /^      containers:/ { exit }
    in_block {
      sub(/^          /, "")
      if ($0 == "set -eu") {
        emit=1
      }
      if (emit) {
        print
      }
    }
  ' "${rendered}" >"${script}"
  chmod +x "${script}"
}

test_remote_handler_imports() {
  local script="$1"
  local case_name="$2"
  local initial_config="$3"
  local expected_import="$4"
  local case_dir="${TMPDIR_ROOT}/remote-handler-${case_name}"
  local remote_dir="${case_dir}/remote"
  local containerd_dir="${case_dir}/containerd"
  local mock_bin="${case_dir}/bin"
  local restart_log="${case_dir}/restarts"

  mkdir -p "${remote_dir}" "${containerd_dir}" "${mock_bin}"
  printf '%s\n' 'remote_hypervisor_socket = "/run/peerpod/caa.sock"' \
    >"${remote_dir}/configuration-remote.toml"
  printf '%s\n' "${initial_config}" >"${containerd_dir}/config.toml"
  cat >"${mock_bin}/nsenter" <<'EOF'
#!/bin/sh
printf 'restart\n' >>"${RESTART_LOG}"
if [ "${RESTART_FAIL:-0}" = "1" ]; then
  exit 1
fi
EOF
  chmod +x "${mock_bin}/nsenter"

  PATH="${mock_bin}:${PATH}" RESTART_LOG="${restart_log}" \
    REMOTE_DIR="${remote_dir}" CONTAINERD_DIR="${containerd_dir}" \
    "${script}" >/dev/null
  assert_contains "${containerd_dir}/config.toml" "${expected_import}"
  assert_count "${restart_log}" '^restart$' 1

  # A second reconciliation must be idempotent and must not restart containerd.
  PATH="${mock_bin}:${PATH}" RESTART_LOG="${restart_log}" \
    REMOTE_DIR="${remote_dir}" CONTAINERD_DIR="${containerd_dir}" \
    "${script}" >/dev/null
  assert_count "${restart_log}" '^restart$' 1

  # A pending marker from a failed restart must trigger a retry and then clear.
  touch "${containerd_dir}/.coco-remote-handlers-restart-required"
  PATH="${mock_bin}:${PATH}" RESTART_LOG="${restart_log}" \
    REMOTE_DIR="${remote_dir}" CONTAINERD_DIR="${containerd_dir}" \
    "${script}" >/dev/null
  assert_count "${restart_log}" '^restart$' 2
  if [[ -e "${containerd_dir}/.coco-remote-handlers-restart-required" ]]; then
    echo "FAIL: restart marker was not cleared after a successful retry" >&2
    exit 1
  fi

  # If containerd kills the reconciler during restart, the attempt marker is
  # consumed on the next pass without triggering a restart loop.
  touch "${containerd_dir}/.coco-remote-handlers-restart-in-progress"
  PATH="${mock_bin}:${PATH}" RESTART_LOG="${restart_log}" \
    REMOTE_DIR="${remote_dir}" CONTAINERD_DIR="${containerd_dir}" \
    "${script}" >/dev/null
  assert_count "${restart_log}" '^restart$' 2
  if [[ -e "${containerd_dir}/.coco-remote-handlers-restart-in-progress" ]]; then
    echo "FAIL: interrupted restart marker was not consumed" >&2
    exit 1
  fi

  # A restart command that reports failure restores the pending marker.
  touch "${containerd_dir}/.coco-remote-handlers-restart-required"
  if PATH="${mock_bin}:${PATH}" RESTART_LOG="${restart_log}" RESTART_FAIL=1 \
    REMOTE_DIR="${remote_dir}" CONTAINERD_DIR="${containerd_dir}" \
    "${script}" >/dev/null 2>&1; then
    echo "FAIL: failed containerd restart returned success" >&2
    exit 1
  fi
  if [[ ! -e "${containerd_dir}/.coco-remote-handlers-restart-required" ]]; then
    echo "FAIL: failed containerd restart did not remain pending" >&2
    exit 1
  fi
}

echo "Rendering multi-provider-minimal.yaml..."
LEGACY_OUT="${TMPDIR_ROOT}/legacy.yaml"
helm template test-release "${CHART_DIR}" \
  -f "${CHART_DIR}/providers/gcp.yaml" \
  --set 'allowedCloudConfigAnnotations[0]=io.katacontainers.config.hypervisor.gcp_zone' \
  >"${LEGACY_OUT}"
assert_contains "${LEGACY_OUT}" 'ALLOWED_CLOUD_CONFIG_ANNOTATIONS: "io.katacontainers.config.hypervisor.gcp_zone"'

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
assert_count "${MINIMAL_OUT}" 'name: peer-pods-secret-gcp' 2
assert_count "${MINIMAL_OUT}" 'name: peer-pods-secret-azure' 2
assert_count "${MINIMAL_OUT}" 'resources: \["pods", "secrets", "serviceaccounts"\]' 2
assert_missing "${MINIMAL_OUT}" 'name: cloud-api-adaptor-(gcp|azure)-pp-secrets'

echo "Rendering provider-specific credentials..."
SECRETS_OUT="${TMPDIR_ROOT}/provider-secrets.yaml"
render "${FIXTURES}/multi-provider-minimal.yaml" "${SECRETS_OUT}" \
  --set-string 'providerSecrets.gcp.GCP_CREDENTIALS=gcp-test-credentials' \
  --set-string 'providerSecrets.azure.AZURE_CLIENT_SECRET=azure-test-secret'
assert_contains "${SECRETS_OUT}" 'GCP_CREDENTIALS: "gcp-test-credentials"'
assert_contains "${SECRETS_OUT}" 'AZURE_CLIENT_SECRET: "azure-test-secret"'

echo "Rendering merged peerpod-ctrl credentials..."
CONTROLLER_SECRETS_OUT="${TMPDIR_ROOT}/controller-secrets.yaml"
render "${FIXTURES}/multi-provider-minimal.yaml" "${CONTROLLER_SECRETS_OUT}" \
  --set 'resourceCtrl.enabled=true' \
  --set-string 'providerSecrets.gcp.GCP_CREDENTIALS=gcp-test-credentials' \
  --set-string 'providerSecrets.azure.AZURE_CLIENT_SECRET=azure-test-secret'
assert_count "${CONTROLLER_SECRETS_OUT}" 'name: peer-pods-secret$' 2
assert_count "${CONTROLLER_SECRETS_OUT}" 'GCP_CREDENTIALS: "gcp-test-credentials"' 2
assert_count "${CONTROLLER_SECRETS_OUT}" 'AZURE_CLIENT_SECRET: "azure-test-secret"' 2

echo "Rendering a shared externally-managed credentials Secret..."
REFERENCE_SECRET_OUT="${TMPDIR_ROOT}/reference-secret.yaml"
render "${FIXTURES}/multi-provider-minimal.yaml" "${REFERENCE_SECRET_OUT}" \
  --set 'secrets.mode=reference' \
  --set 'secrets.existingSecretName=cloud-credentials'
assert_count "${REFERENCE_SECRET_OUT}" 'name: cloud-credentials' 2
assert_missing "${REFERENCE_SECRET_OUT}" 'optional: true'

echo "Expecting maxUnavailable=0 to fail when maxSurge=0..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/zero-unavailable.yaml" \
  --set 'providers[0].maxUnavailable=0' 2>"${TMPDIR_ROOT}/zero-unavailable.err"; then
  echo "FAIL: zero maxUnavailable and maxSurge rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/zero-unavailable.err" 'maxUnavailable must be greater than 0 because maxSurge is 0'

echo "Rendering webhook alias from its chart defaults..."
WEBHOOK_DEFAULTS_OUT="${TMPDIR_ROOT}/webhook-defaults.yaml"
render "${FIXTURES}/multi-provider-minimal.yaml" "${WEBHOOK_DEFAULTS_OUT}" \
  --set 'webhookGcp.enabled=true'
assert_contains "${WEBHOOK_DEFAULTS_OUT}" 'peer-pods-webhook-gcp-'

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
assert_count "${HYBRID_OUT}" '^scheduling:$' 2
assert_count "${HYBRID_OUT}" '^  nodeSelector:$' 2
assert_count "${HYBRID_OUT}" '^  tolerations:$' 2
assert_count "${HYBRID_OUT}" '^    cohere.com/caa-worker: "true"$' 2
assert_count "${HYBRID_OUT}" 'pool: gcp-confidential' 2
assert_count "${HYBRID_OUT}" 'key: gcp-confidential' 3
assert_count "${HYBRID_OUT}" 'key: kata.peerpods.io/vm' 5
assert_count "${HYBRID_OUT}" 'mountPath: /etc/certificates' 2
assert_count "${HYBRID_OUT}" 'secretName: certs-for-tls' 2
assert_contains "${HYBRID_OUT}" 'type: DirectoryOrCreate'
# Shared config is present in the controller and both provider ConfigMaps.
assert_count "${HYBRID_OUT}" 'PROXY_TIMEOUT: "30m"' 3
assert_count "${HYBRID_OUT}" 'DISABLECVM: "false"' 3
assert_count "${HYBRID_OUT}" 'CACERT_FILE: "/etc/certificates/ca.crt"' 3

echo "Executing rendered remote-handler script against containerd fixtures..."
HANDLER_SCRIPT="${TMPDIR_ROOT}/remote-handler.sh"
extract_remote_handler_script "${HYBRID_OUT}" "${HANDLER_SCRIPT}"
test_remote_handler_imports "${HANDLER_SCRIPT}" "missing" \
  'version = 2' \
  '^imports = \["/etc/containerd/coco-remote-handlers.toml"\]$'
test_remote_handler_imports "${HANDLER_SCRIPT}" "empty" \
  'imports = []' \
  '^imports = \["/etc/containerd/coco-remote-handlers.toml"\]$'
test_remote_handler_imports "${HANDLER_SCRIPT}" "single-line" \
  'imports = ["/etc/containerd/existing.toml"]' \
  '^imports = \["/etc/containerd/existing.toml", "/etc/containerd/coco-remote-handlers.toml"\]$'
test_remote_handler_imports "${HANDLER_SCRIPT}" "multi-line" \
  $'imports = [\n  "/etc/containerd/existing.toml",\n]' \
  '^[[:space:]]*"/etc/containerd/coco-remote-handlers.toml",$'
test_remote_handler_imports "${HANDLER_SCRIPT}" "already-patched" \
  'imports = ["/etc/containerd/coco-remote-handlers.toml"]' \
  '^imports = \["/etc/containerd/coco-remote-handlers.toml"\]$'

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

echo "Expecting raw multi-provider allowlist override to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/raw-allowlist.yaml" \
  --set-string 'providers[0].config.ALLOWED_CLOUD_CONFIG_ANNOTATIONS=io.katacontainers.config.hypervisor.gcp_zone' \
  2>"${TMPDIR_ROOT}/raw-allowlist.err"; then
  echo "FAIL: raw multi-provider allowlist rendered successfully" >&2
  exit 1
fi
if ! grep -q 'config.ALLOWED_CLOUD_CONFIG_ANNOTATIONS is managed by the chart' "${TMPDIR_ROOT}/raw-allowlist.err"; then
  echo "FAIL: expected managed allowlist error, got:" >&2
  cat "${TMPDIR_ROOT}/raw-allowlist.err" >&2
  exit 1
fi

echo "Expecting maxSurge>0 to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/max-surge.yaml" \
  --set 'providers[0].maxSurge=1' 2>"${TMPDIR_ROOT}/max-surge.err"; then
  echo "FAIL: maxSurge=1 rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/max-surge.err" 'maxSurge must be 0'

echo "Expecting conflicting provider node selector to fail..."
if render "${FIXTURES}/multi-provider-hybrid.yaml" "${TMPDIR_ROOT}/selector-conflict.yaml" \
  --set-string 'providers[0].nodeSelector.cohere\.com/caa-worker=false' \
  2>"${TMPDIR_ROOT}/selector-conflict.err"; then
  echo "FAIL: conflicting provider node selector rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/selector-conflict.err" 'nodeSelector.*conflicts with the top-level nodeSelector'

echo "Expecting invalid provider name to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/invalid-name.yaml" \
  --set 'providers[0].name=GCP_bad' 2>"${TMPDIR_ROOT}/invalid-name.err"; then
  echo "FAIL: invalid provider name rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/invalid-name.err" 'name must be a valid DNS-1123 label'

echo "Expecting invalid RuntimeClass name to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/invalid-runtime-class.yaml" \
  --set 'providers[0].runtimeClassName=Invalid_Name' 2>"${TMPDIR_ROOT}/invalid-runtime-class.err"; then
  echo "FAIL: invalid RuntimeClass name rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/invalid-runtime-class.err" 'runtimeClassName must be a valid DNS-1123 label'

echo "Expecting the legacy default webhook to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/legacy-webhook.yaml" \
  --set 'webhook.enabled=true' 2>"${TMPDIR_ROOT}/legacy-webhook.err"; then
  echo "FAIL: legacy default webhook rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/legacy-webhook.err" 'webhook.enabled must be false in multi-provider mode'

echo "Expecting unsupported cloud provider to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/unsupported-provider.yaml" \
  --set 'providers[0].cloudProvider=aws' 2>"${TMPDIR_ROOT}/unsupported-provider.err"; then
  echo "FAIL: unsupported cloud provider rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/unsupported-provider.err" 'cloudProvider must be one of: gcp, azure'

echo "Expecting an unsafe extended resource name to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/extended-resource.yaml" \
  --set 'providers[0].extendedResource=example.com/arbitrary-capacity' \
  2>"${TMPDIR_ROOT}/extended-resource.err"; then
  echo "FAIL: unsafe extended resource name rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/extended-resource.err" 'extendedResource must match kata.peerpods.io/vm-<provider>'

echo "Expecting legacy Workload Identity settings to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/legacy-wif.yaml" \
  --set 'gcpWorkloadIdentity.enabled=true' 2>"${TMPDIR_ROOT}/legacy-wif.err"; then
  echo "FAIL: legacy Workload Identity setting rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/legacy-wif.err" 'gcpWorkloadIdentity is a legacy single-provider value'

echo "Expecting missing peerpod-ctrl GCP identity to fail..."
if render "${FIXTURES}/multi-provider-hybrid.yaml" "${TMPDIR_ROOT}/missing-controller-gcp-wi.yaml" \
  --set-string 'resourceCtrl.serviceAccount.annotations.iam\.gke\.io/gcp-service-account=' \
  2>"${TMPDIR_ROOT}/missing-controller-gcp-wi.err"; then
  echo "FAIL: missing peerpod-ctrl GCP identity rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/missing-controller-gcp-wi.err" 'gcp-service-account is required when GCP Workload Identity Federation is enabled'

echo "Expecting a missing referenced credentials Secret name to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/missing-reference.yaml" \
  --set 'secrets.mode=reference' 2>"${TMPDIR_ROOT}/missing-reference.err"; then
  echo "FAIL: empty secrets.existingSecretName rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/missing-reference.err" 'secrets.existingSecretName is required'

echo "Expecting a nonstandard peerpod-ctrl credentials Secret name to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/controller-reference.yaml" \
  --set 'resourceCtrl.enabled=true' \
  --set 'secrets.mode=reference' \
  --set 'secrets.existingSecretName=custom-cloud-credentials' \
  2>"${TMPDIR_ROOT}/controller-reference.err"; then
  echo "FAIL: unsupported peerpod-ctrl credentials Secret name rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/controller-reference.err" 'resourceCtrl requires secrets.existingSecretName=peer-pods-secret'

echo "Expecting an unknown webhook RuntimeClass to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/webhook-runtime.yaml" \
  --set 'webhookGcp.enabled=true' \
  --set 'webhookGcp.webhook.targetRuntimeClass=kata-remote-unknown' \
  2>"${TMPDIR_ROOT}/webhook-runtime.err"; then
  echo "FAIL: unknown webhook RuntimeClass rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/webhook-runtime.err" 'must match an enabled providers\[\].runtimeClassName'

echo "Expecting duplicate webhook prefixes to fail..."
if render "${FIXTURES}/multi-provider-minimal.yaml" "${TMPDIR_ROOT}/webhook-prefix.yaml" \
  --set 'webhookGcp.enabled=true' \
  --set 'webhookAzure.enabled=true' \
  --set 'webhookAzure.namePrefix=peer-pods-webhook-gcp-' \
  2>"${TMPDIR_ROOT}/webhook-prefix.err"; then
  echo "FAIL: duplicate webhook namePrefix rendered successfully" >&2
  exit 1
fi
assert_contains "${TMPDIR_ROOT}/webhook-prefix.err" 'namePrefix must be unique'

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

echo "Verifying tests are excluded from the packaged chart..."
helm package "${CHART_DIR}" --destination "${TMPDIR_ROOT}" >/dev/null
PACKAGES=("${TMPDIR_ROOT}"/peerpods-*.tgz)
PACKAGE="${PACKAGES[0]}"
tar -tzf "${PACKAGE}" >"${TMPDIR_ROOT}/package-contents"
if grep -q '/tests/' "${TMPDIR_ROOT}/package-contents"; then
  echo "FAIL: chart package contains tests/" >&2
  exit 1
fi

echo "Multi-provider chart checks passed"
