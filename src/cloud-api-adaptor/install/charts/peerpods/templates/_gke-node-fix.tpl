{{- define "peerpods.gkeNodeFixInitContainers" -}}
- name: fix-containerd
  image: alpine:3.21
  securityContext:
    privileged: true
  volumeMounts:
  - name: host-containerd-config
    mountPath: /etc/containerd
  command:
  - /bin/sh
  - -c
  - |
    TOML=/etc/containerd/config.toml

    if grep -q 'discard_unpacked_layers = false' "$TOML"; then
      echo "containerd: already patched, skipping"
      exit 0
    fi

    if grep -q 'discard_unpacked_layers = true' "$TOML"; then
      sed -i 's/discard_unpacked_layers = true/discard_unpacked_layers = false/g' "$TOML"
      echo "containerd: patched $TOML"
      grep discard_unpacked_layers "$TOML"
      nsenter -t 1 -m -u -i -n -p -- systemctl restart containerd
      echo "containerd: restarted"
    else
      echo "containerd: discard_unpacked_layers setting not found, skipping restart"
      grep discard_unpacked_layers "$TOML" || true
    fi
- name: fix-kubelet
  image: alpine:3.21
  securityContext:
    privileged: true
  volumeMounts:
  - name: host-kubelet-config
    mountPath: /home/kubernetes
  command:
  - /bin/sh
  - -c
  - |
    CONFIG=/home/kubernetes/kubelet-config.yaml
    DESIRED="{{ .Values.gkeNodeFix.runtimeRequestTimeout }}"

    if grep -q "runtimeRequestTimeout: \"$DESIRED\"" "$CONFIG" 2>/dev/null; then
      echo "kubelet: already set to $DESIRED, skipping"
      exit 0
    fi

    if grep -q "runtimeRequestTimeout:" "$CONFIG"; then
      sed -i "s/runtimeRequestTimeout:.*/runtimeRequestTimeout: \"$DESIRED\"/" "$CONFIG"
    else
      echo "runtimeRequestTimeout: \"$DESIRED\"" >> "$CONFIG"
    fi

    echo "kubelet: patched $CONFIG"
    grep runtimeRequestTimeout "$CONFIG"

    nsenter -t 1 -m -u -i -n -p -- systemctl restart kubelet
    echo "kubelet: restarted"
{{- end -}}
