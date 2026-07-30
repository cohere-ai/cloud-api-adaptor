{{- define "peerpods.remoteHandlerScript" -}}
set -eu

REMOTE_DIR="${REMOTE_DIR:-/opt/kata/share/defaults/kata-containers/runtimes/remote}"
BASE="$REMOTE_DIR/configuration-remote.toml"
CONTAINERD_DIR="${CONTAINERD_DIR:-/etc/containerd}"
DROPIN="$CONTAINERD_DIR/coco-remote-handlers.toml"
TOML="$CONTAINERD_DIR/config.toml"
RESTART_REQUIRED="$CONTAINERD_DIR/.coco-remote-handlers-restart-required"
CHANGED=0

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
elif grep -Eq '^imports = \[[[:space:]]*\]' "$TOML"; then
  # Empty imports = [] must be replaced, not appended into (avoids imports = [, "..."]).
  sed -i.bak 's#^imports = \[[[:space:]]*\]#imports = ["/etc/containerd/coco-remote-handlers.toml"]#' "$TOML"
  rm -f "$TOML.bak"
  CHANGED=1
  echo "replaced empty containerd imports with $DROPIN"
elif grep -Eq '^imports = \[[[:space:]]*$' "$TOML"; then
  sed -i.bak '/^imports = \[[[:space:]]*$/a\
  "/etc/containerd/coco-remote-handlers.toml",
' "$TOML"
  rm -f "$TOML.bak"
  grep -q 'coco-remote-handlers.toml' "$TOML" || {
    echo "failed to add $DROPIN to multi-line containerd imports" >&2
    exit 1
  }
  CHANGED=1
  echo "added $DROPIN to multi-line containerd imports"
elif grep -Eq '^imports = \[[^]]*\][[:space:]]*$' "$TOML"; then
  sed -i.bak 's#^imports = \[\(.*\)\]#imports = [\1, "/etc/containerd/coco-remote-handlers.toml"]#' "$TOML"
  rm -f "$TOML.bak"
  grep -q 'coco-remote-handlers.toml' "$TOML" || {
    echo "failed to add $DROPIN to containerd imports" >&2
    exit 1
  }
  CHANGED=1
  echo "added $DROPIN to containerd imports"
else
  printf '\nimports = ["/etc/containerd/coco-remote-handlers.toml"]\n' >> "$TOML"
  CHANGED=1
  echo "created containerd imports for $DROPIN"
fi
grep '^imports' "$TOML" || true

if [ "$CHANGED" = "1" ]; then
  touch "$RESTART_REQUIRED"
fi

if [ -f "$RESTART_REQUIRED" ]; then
  nsenter -t 1 -m -u -i -n -p -- systemctl restart containerd
  rm -f "$RESTART_REQUIRED"
  echo "containerd restarted after remote handler reconciliation"
else
  echo "remote handler config already current"
fi
{{- end -}}
