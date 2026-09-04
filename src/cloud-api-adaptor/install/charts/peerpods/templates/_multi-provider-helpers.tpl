{{/* Common labels for resources rendered by multi-provider mode. */}}
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
Return "true" when a providers[] entry is enabled. This uses hasKey because
Sprig's default function treats an explicit false value as empty.
*/}}
{{- define "peerpods.providerEnabled" -}}
{{- if hasKey . "enabled" -}}
{{- if .enabled -}}true{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/* Resolve the provider credentials Secret used by a multi-provider CAA. */}}
{{- define "peerpods.providerSecretName" -}}
{{- if eq .root.Values.secrets.mode "reference" -}}
{{- .root.Values.secrets.existingSecretName -}}
{{- else -}}
peer-pods-secret-{{ .provider.name }}
{{- end -}}
{{- end -}}

{{/* Kubernetes ServiceAccount name for a provider CAA. Defaults to
     cloud-api-adaptor-<provider.name>; set serviceAccount.name to reuse an
     existing identity (for example the single-provider cloud-api-adaptor SA). */}}
{{- define "peerpods.providerServiceAccountName" -}}
{{- $sa := .serviceAccount | default dict -}}
{{- if $sa.name -}}
{{- $sa.name -}}
{{- else -}}
cloud-api-adaptor-{{ .name }}
{{- end -}}
{{- end -}}

{{/* Merge provider ServiceAccount annotations with Azure identity metadata. */}}
{{- define "peerpods.providerServiceAccountAnnotations" -}}
{{- $sa := .serviceAccount | default dict -}}
{{- $annotations := deepCopy ($sa.annotations | default dict) -}}
{{- if and .azureWorkloadIdentity .azureWorkloadIdentity.enabled -}}
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

{{/* Resolve the audience used by a projected GCP Workload Identity token. */}}
{{- define "peerpods.providerGcpTokenAudience" -}}
{{- if .tokenAudience -}}
{{- .tokenAudience -}}
{{- else -}}
{{- $audience := .audience | default "" -}}
{{- if hasPrefix "//" $audience -}}https:{{ $audience }}{{- else -}}{{ $audience }}{{- end -}}
{{- end -}}
{{- end -}}

{{/* Return "true" when this provider mounts custom TLS certificates. */}}
{{- define "peerpods.providerHasTlsCerts" -}}
{{- $config := mergeOverwrite (deepCopy (.provider.config | default dict)) (.root.Values.sharedConfig | default dict) -}}
{{- if and (index $config "CACERT_FILE") (include "peerpods.tlsSecretName" .root) -}}
true
{{- end -}}
{{- end -}}
