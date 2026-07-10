{{/*
Helper templates for peerpods chart
*/}}

{{- define "peerpods.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "peerpods.labels" -}}
app.kubernetes.io/name: {{ include "peerpods.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "peerpods.providerLabels" -}}
{{ include "peerpods.labels" .root }}
app.kubernetes.io/component: cloud-api-adaptor
peerpods.confidentialcontainers.org/provider: {{ .provider.name | quote }}
{{- end -}}

{{/*
Return "true" when a providers[] entry is enabled (default true).

Sprig `default` treats boolean false as empty, so `default true false`
incorrectly yields true. Use hasKey so enabled: false is honored.
*/}}
{{- define "peerpods.providerEnabled" -}}
{{- if hasKey . "enabled" -}}
{{- if .enabled -}}true{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Render ServiceAccount annotations for a providers[] entry.
Merges optional serviceAccount.annotations with Azure Workload Identity
annotations when enabled. Safe when serviceAccount is omitted.
*/}}
{{- define "peerpods.providerServiceAccountAnnotations" -}}
{{- $sa := .serviceAccount | default dict -}}
{{- $annotations := dict -}}
{{- range $key, $value := ($sa.annotations | default dict) -}}
{{- $_ := set $annotations $key $value -}}
{{- end -}}
{{- if and .azureWorkloadIdentity .azureWorkloadIdentity.enabled -}}
{{- if not .azureWorkloadIdentity.clientId -}}
{{- fail (printf "providers.%s.azureWorkloadIdentity.clientId is required" .name) -}}
{{- end -}}
{{- $_ := set $annotations "azure.workload.identity/client-id" .azureWorkloadIdentity.clientId -}}
{{- if .azureWorkloadIdentity.tenantId -}}
{{- $_ := set $annotations "azure.workload.identity/tenant-id" .azureWorkloadIdentity.tenantId -}}
{{- end -}}
{{- end -}}
{{- if $annotations -}}
annotations:
{{ toYaml $annotations | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "peerpods.providerGcpTokenAudience" -}}
{{- if .tokenAudience -}}
{{- .tokenAudience -}}
{{- else -}}
{{- $aud := .audience | default "" -}}
{{- if hasPrefix "//" $aud -}}
https:{{ $aud }}
{{- else -}}
{{- $aud -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the appropriate secret name based on secrets.mode:
- "create": Use the chart-managed secret (peer-pods-secret)
- "reference": Use the user-provided existing secret name (validated)
*/}}
{{- define "peerpods.secretName" -}}
{{- if eq .Values.secrets.mode "reference" -}}
{{- .Values.secrets.existingSecretName -}}
{{- else -}}
peer-pods-secret
{{- end -}}
{{- end -}}

{{/*
Return the SSH key secret name for providers that use SSH (libvirt, byom):
- "create": Use the chart-managed secret (ssh-key-secret)
- "reference": Use the user-provided existing secret name (validated)
*/}}
{{- define "peerpods.sshKeySecretName" -}}
{{- if eq .Values.secrets.mode "reference" -}}
{{- .Values.secrets.existingSshKeySecretName -}}
{{- else -}}
ssh-key-secret
{{- end -}}
{{- end -}}

{{/*
Return the TLS secret name for custom certificates:
- "create": Use the chart-managed secret (certs-for-tls)
- "reference": Use the user-provided existing secret name (validated)
*/}}
{{- define "peerpods.tlsSecretName" -}}
{{- if eq .Values.secrets.mode "reference" -}}
{{- .Values.secrets.existingTlsSecretName -}}
{{- else -}}
certs-for-tls
{{- end -}}
{{- end -}}

{{/*
Alibaba Cloud RRSA: mount projected service account token when enabled.
Uses chained `and` (short-circuit) so missing .Values.alibabacloud / .rrsa is safe.
Returns non-empty "true" when the RRSA volume should be rendered.
*/}}
{{- define "peerpods.alibabacloudRrsaEnabled" -}}
{{- if and (eq .Values.provider "alibabacloud") .Values.alibabacloud .Values.alibabacloud.rrsa .Values.alibabacloud.rrsa.enable -}}
true
{{- end -}}
{{- end -}}

{{/*
GCP Workload Identity Federation: render the external_account ConfigMap + token
mount when enabled. Only meaningful for provider=gcp; short-circuits if the
block is missing or disabled.
*/}}
{{- define "peerpods.gcpWorkloadIdentityEnabled" -}}
{{- if and (eq .Values.provider "gcp") .Values.gcpWorkloadIdentity .Values.gcpWorkloadIdentity.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
GCP WIF: resolve the projected-token audience. Defaults to the `audience` value
with the leading "//" stripped (the STS audience format takes "//...", but
Kubernetes projected tokens take the https:// URL form).
*/}}
{{- define "peerpods.gcpWorkloadIdentityTokenAudience" -}}
{{- if .Values.gcpWorkloadIdentity.tokenAudience -}}
{{- .Values.gcpWorkloadIdentity.tokenAudience -}}
{{- else -}}
{{- $aud := .Values.gcpWorkloadIdentity.audience | default "" -}}
{{- if hasPrefix "//" $aud -}}
https:{{ $aud }}
{{- else -}}
{{- $aud -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check if custom TLS certificates are configured.
Returns "true" when CACERT_FILE is set in providerConfigs for the active
provider AND a TLS secret name is available (either chart-managed or external).
*/}}
{{- define "peerpods.hasTlsCerts" -}}
{{- $config := dict }}
{{- if .Values.providerConfigs }}
{{- $config = index .Values.providerConfigs .Values.provider | default dict }}
{{- end }}
{{- if and (index $config "CACERT_FILE") (include "peerpods.tlsSecretName" .) -}}
true
{{- end -}}
{{- end -}}

{{- define "peerpods.remoteHandlerScript" -}}
set -eu

REMOTE_DIR=/opt/kata/share/defaults/kata-containers/runtimes/remote
BASE="$REMOTE_DIR/configuration-remote.toml"
DROPIN=/etc/containerd/coco-remote-handlers.toml
TOML=/etc/containerd/config.toml
CHANGED=0

i=0
while [ ! -f "$BASE" ] && [ "$i" -lt 60 ]; do
  sleep 5
  i=$((i + 1))
done
[ -f "$BASE" ] || { echo "base remote config missing at $BASE"; exit 1; }

write_if_changed() {
  src="$1"
  dst="$2"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    rm -f "$src"
    return
  fi
  mv "$src" "$dst"
  CHANGED=1
  echo "updated $dst"
}

make_cfg() {
  name="$1"
  socket="$2"
  out="$REMOTE_DIR/configuration-remote-$name.toml"
  tmp="$(mktemp)"
  sed "s#^remote_hypervisor_socket = .*#remote_hypervisor_socket = \"$socket\"#" "$BASE" > "$tmp"
  write_if_changed "$tmp" "$out"
  grep remote_hypervisor_socket "$out"
}

{{- range $provider := .Values.providers }}
{{- if include "peerpods.providerEnabled" $provider }}
make_cfg {{ $provider.name | quote }} {{ $provider.socketPath | quote }}
{{- end }}
{{- end }}

tmp="$(mktemp)"
{
{{- range $provider := .Values.providers }}
{{- if include "peerpods.providerEnabled" $provider }}
  printf '%s\n' \
    '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.{{ $provider.runtimeClassName }}]' \
    'runtime_type = "io.containerd.kata-remote.v2"' \
    'runtime_path = "/opt/kata/bin/containerd-shim-kata-v2"' \
    'privileged_without_host_devices = true' \
    'pod_annotations = ["io.katacontainers.*"]' \
    'container_annotations = ["io.kubernetes.container.terminationMessage*"]' \
    '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.{{ $provider.runtimeClassName }}.options]' \
    'ConfigPath = "/opt/kata/share/defaults/kata-containers/runtimes/remote/configuration-remote-{{ $provider.name }}.toml"' \
    ''
{{- end }}
{{- end }}
} > "$tmp"
write_if_changed "$tmp" "$DROPIN"

if grep -q 'coco-remote-handlers.toml' "$TOML"; then
  echo "containerd imports already include $DROPIN"
elif grep -q '^imports = \[' "$TOML"; then
  sed -i 's#^imports = \[\(.*\)\]#imports = [\1, "/etc/containerd/coco-remote-handlers.toml"]#' "$TOML"
  CHANGED=1
  echo "added $DROPIN to containerd imports"
else
  printf '\nimports = ["/etc/containerd/coco-remote-handlers.toml"]\n' >> "$TOML"
  CHANGED=1
  echo "created containerd imports for $DROPIN"
fi
grep '^imports' "$TOML" || true

if [ "$CHANGED" = "1" ]; then
  nsenter -t 1 -m -u -i -n -p -- systemctl restart containerd
  echo "containerd restarted after remote handler reconciliation"
else
  echo "remote handler config already current"
fi
{{- end -}}
