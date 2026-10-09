# Cohere follow-ups

Open review findings on the Cohere patches, kept on the version branch so they
are not lost between upgrades. Each item names the patch that owns the fix.

Fixes land on the newest version branch, folded into that patch with
`git commit --fixup` (not as separate "review fixes" patches). Older version
branches only get a fix if it is backported deliberately; the item says so.

When an item is fixed, move it to **Done** with the version branch and commit,
and keep its verification step: run it again after every upgrade. Remove an
item only when its owning patch is dropped or upstream ships the fix.

Source: review of the `cohere-v0.21.1` patch series by @alhassankhedr-cohere
on [PR #100](https://github.com/cohere-ai/cloud-api-adaptor/pull/100), carried
to `cohere-v0.22.0` and `cohere-v0.23.0`. Paths below are the post-v0.22
locations (`podvm-mkosi/` merged into `podvm/` upstream).

## Open: fix

### F1. RTMR3 helper delays every non-TDX boot by 30 seconds

- Patch: `podvm: Ubuntu image with NVIDIA GPU and TDX RTMR3 initdata`
- File: `src/cloud-api-adaptor/podvm/mkosi.images/system/mkosi.skeleton/usr/local/bin/extend-rtmr3-initdata`
- Review: [r4222327724](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327724)

On SEV-SNP and other non-TDX VMs the script polls for `/dev/tdx_guest` 30
times, one second apart, before deciding it is not a TDX guest. It runs as
`ExecStartPost` of `process-user-data.service`, so the PCR8 extend and every
agent ordered after that unit wait the full 30 seconds on every boot.

Fix: check the `tdx_guest` CPU flag once (`grep -qw tdx_guest /proc/cpuinfo`)
and exit 0 if it is absent. Keep the device wait only for TDX guests, where
`/dev/tdx_guest` can appear after the unit starts (GCP). If a TDX guest never
gets the device, exit non-zero instead of skipping, matching the existing
handling of a missing RTMR3 measurement node.

Do not use `/sys/firmware/tdx`: it describes a TDX host, not a guest. A
CPU-vendor check would still wait 30 seconds on non-confidential Intel VMs.

Verify: boot an SNP (or plain) PodVM and check that
`journalctl -u process-user-data` logs the skip with no `waiting for
/dev/tdx_guest` lines; boot on GCP TDX and confirm the smoke test's RTMR3
still matches.

### F2. `dd` can do a short read from the pipe

- Patch: `podvm: Ubuntu image with NVIDIA GPU ...`
- File: `extend-rtmr3-initdata` (same as F1)
- Review: [r4222327736](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327736)

Fix: add `iflag=fullblock` to the `dd` that writes the 48-byte digest.

Verify: `grep -n 'iflag=fullblock' extend-rtmr3-initdata`; RTMR3 smoke test
still passes.

### F3. Preempted GCP spot VMs stop instead of being deleted

- Patch: `gcp: add spot VMs and network tags`
- File: `src/cloud-providers/gcp/provider.go` (spot `Scheduling` block)
- Review: [r4222327742](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327742)

Only `ProvisioningModel: SPOT` is set. Without `InstanceTerminationAction`, GCP
stops a preempted VM, and the stopped VM and its disk keep existing (and
billing) until cleanup. Azure already uses `EvictionPolicy: Delete`.

Fix: set `InstanceTerminationAction: proto.String("DELETE")` on the
`Scheduling` when spot is on. Backport candidate to `cohere-v0.21.1` (cost
leak) if another v0.21.x release is cut.

Verify: unit test asserting `Scheduling.GetInstanceTerminationAction() ==
"DELETE"` for a spot instance; on dev,
`gcloud compute instances describe <peer-pod-vm> --format='value(scheduling.instanceTerminationAction)'`
prints `DELETE`.

### F8. Boot stub override now downgrades systemd-stub

- Patch: `podvm: Ubuntu image with NVIDIA GPU ...`
- Files: `src/cloud-api-adaptor/podvm/Dockerfile.mkosi` (24.10 builder),
  `src/cloud-api-adaptor/podvm/mkosi.images/system/mkosi.postinst` (stub copy)

Upstream v0.23 builds the image on Ubuntu 26.04, whose `systemd-boot-efi`
ships systemd-stub 259.5. The override still copies the builder's 256.5 stub
from Ubuntu 24.10 (EOL) over it, so the UKI boots an older stub than the
image provides. It was added because 24.04's 255 stub did not produce the
RTMR2 that cvm-measure predicts.

The builder is also EOL Ubuntu 24.10, which gets no more security updates
(old H3, [r4222327719](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327719)).
The build now fails if the builder has no v256 stub, instead of silently
shipping the image's stub and an RTMR2 that does not match the prediction.

Fix: drop the 24.10 builder and the stub copy, use the image's own stub, and
teach cvm-measure the v259 RTMR2 format if it differs.

Verify: the UKI's `.osrel`/stub version is 259; the GCP TDX smoke test's RTMR2
matches the build's prediction.

### F9. NVIDIA packages come from the Ubuntu 24.04 repository

- Patch: `podvm: Ubuntu image with NVIDIA GPU ...`
- Files: `src/cloud-api-adaptor/podvm/mkosi.sandbox/etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list`,
  `src/cloud-api-adaptor/podvm/Dockerfile.mkosi` (keyring),
  `src/cloud-api-adaptor/podvm/mkosi.images/system/mkosi.conf.d/ubuntu-amd64.conf`
  (package pins)

The image is Ubuntu 26.04 with kernel 7.0, but the NVIDIA CUDA repository is
NVIDIA's `ubuntu2404` one. The pinned 580.178.04 driver builds against kernel
7.0 with DKMS (the v0.23 test build installed `nvidia.ko`), but NVIDIA does
not publish 580 for 26.04: its `ubuntu2604` repository starts at 610.57.
DKMS also logged `zstd: command not found` while building the modules.

The image now uses upstream's plain `linux-image-generic` with
`linux-headers-generic` (the misleading `*-hwe-24.04` names are gone), and the
GPU packages live in `ubuntu-amd64.conf`, so arm64 and s390x builds no longer
pull amd64-only NVIDIA packages.

Fix (needs an owner decision, it changes the GPU driver): either keep 580
from the 24.04 repository deliberately and document it, or move to the
`ubuntu2604` repository and a 610/615 driver, re-validating CUDA
compatibility, NVIDIA confidential-computing mode and attestation. In both
cases add `zstd` to the image packages.

Verify: on a GCP TDX GPU peer pod, `nvidia-smi` works and
`nvidia-smi conf-compute -grs` reports ready; GPU attestation passes.

## Open: hardening

### H1. Privileged node helpers pull images by tag

- Patches: `chart: Cohere defaults, GCP workload identity and GKE node fixes`,
  `chart: support multiple peer pod providers`
- Files: `templates/node-config-multi-provider.yaml` (2x `alpine:3.21`),
  `templates/_gke-node-fix.tpl` (2x `alpine:3.21`),
  `templates/fix-gke-node-config.yaml` (`registry.k8s.io/pause:3.10`)
- Review: [r4222327703](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327703)

These containers run privileged with `hostPID` and `nsenter -t 1`, which is
root on every CAA node. Pin by digest and make the images configurable in
`values.yaml`.

Verify: `grep -rn 'image:' templates/ | grep -v '@sha256:'` returns nothing for
these files; `make static-helm-check` passes.

### H2. NVIDIA APT keyrings are trusted without a fingerprint check

- Patch: `podvm: Ubuntu image with NVIDIA GPU ...`
- File: `src/cloud-api-adaptor/podvm/Dockerfile.mkosi` (keyring download)
- Review: [r4222327713](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327713)

Fix: after download, compare `gpg --show-keys --with-colons` fingerprints
against pinned values and fail on mismatch, or commit the keyrings.

### H5. Deploy jobs have no protected environment

- Patch: `ci: build, smoke test and deploy Cohere PodVM images`
- Files: `deploy-gcp-cohere.yaml`, `deploy-azure-cohere.yaml`,
  `build-podvm-cohere.yaml`, `.github/zizmor.yml`
- Review: [r4222327778](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327778)

Deploy access rests only on the cloud-side OIDC subject conditions. Add a
protected `environment:` (required reviewers, `cohere` and `cohere-v*` only,
the branches that publish) to the GCP and Azure deploy jobs, and update the
GCP Workload Identity and Azure federated credential subjects to match. The
Azure credential does not trust `cohere-v0.23.0` yet: `deploy-azure-cohere`
fails with `AADSTS7002131` from that branch.

Once there is an environment, move `GH_APP_CLIENT_ID` and `GH_APP_PRIVATE_KEY`
into it and drop the `secrets-outside-env` allowance in `.github/zizmor.yml`.
Both need repository settings changes, not just code.

Verify: deploy jobs wait for environment approval; zizmor passes without the
allowance.

### H6. govulncheck reports fixable Go and x/net findings

- Patch: none on `cohere-v0.23.0` (the v0.22 deps patch is dropped; a new
  deps patch would own the fix)
- Check: `lint / govulncheck` (not required to merge)

On `cohere-v0.23.0` (Go 1.26.7) CI govulncheck reports:

- Go 1.26.7 standard library (GO-2026-6599/6600/6603/6605/6607/6608/6610/
  6611/6612/6613/6617), fixed in Go 1.26.9.
- `golang.org/x/net` 0.58 (HTTP/2 subset of the above), fixed in 0.60.
- containerd 1.7.35 image-pull DoS (GO-2026-6597), fixed in 1.7.36.
- Three containerd CRI checkpoint issues (GO-2026-5064/5338/5622) with no fix.
  Upstream v0.23 already lists these in `.govulncheck-ignore.toml`.

Fix: a deps patch that bumps Go to 1.26.9, x/net to 0.60 and containerd to
1.7.36, or take them from upstream if it gets there first.

History:

On `cohere-v0.21.1` and `cohere-v0.22.0` govulncheck reports findings from the
Go 1.25.12 standard library (fixed in 1.25.13 or 1.26.9) and from
`golang.org/x/net` (fixed in 0.60). On `cohere-v0.21.1` it also reports
`golang.org/x/crypto` 0.52, gRPC 1.82.1 (fixed in 1.83.1), containerd 1.7.34
(some fixed in 1.7.35/1.7.36, three CRI checkpoint issues with no fix) and
`github.com/docker/docker` 28.5.2 (no fix). On `cohere-v0.22.0` the webhook
module still has gRPC 1.79.3 and otel 1.34. The same check failed on `cohere`
and on PR #67.

Upstream v0.23.0 moved to Go 1.26.7, containerd 1.7.35 and gRPC 1.83.2,
which fixed those. If a finding with no fix appears, list it in
`.govulncheck-ignore.toml` with a reason; `hack/govulncheck.sh` reads that
file.

Verify: `make govulncheck` exits 0 on the version branch.

### H7. GKE node fix runs on every GKE node by default

- Patch: `chart: Cohere defaults, GCP workload identity and GKE node fixes`
- Files: `install/charts/peerpods/values.yaml` (top-level `nodeSelector: {}`),
  `templates/fix-gke-node-config.yaml`
- Review: [r4233162107](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4233162107)

The fix now defaults on only for GCP (D9), but it still inherits the empty
top-level `nodeSelector`. A default GCP install runs its privileged, `hostPID`
DaemonSet on every GKE node: it rewrites containerd and kubelet config and
restarts both. Our environments are safe only because their values set
`nodeSelector: {cohere.com/caa-worker: "true"}`.

Fix: fail rendering when the fix is enabled with an empty `nodeSelector`.

Verify: enabling it without a `nodeSelector` fails with a clear error;
`make static-helm-check` passes.

### H8. Remote shim drop-in for disable_guest_empty_dir

- Patch: `chart: Cohere defaults, GCP workload identity and GKE node fixes`
- File: `install/charts/peerpods/values.yaml` (`kata-deploy.shims.remote.dropIn`)

genpolicy 4.x only generates emptyDir rules for `disable_guest_empty_dir =
true` (kata-containers#12373), but the Go runtime's
`configuration-remote.toml` still hard-codes `false`. runtime-rs already
removed the option (kata-containers#13280). The chart sets `true` through a
kata-deploy drop-in; without it every peer pod with an emptyDir is rejected by
its policy.

Fix: file the Kata issue or PR so `configuration-remote.toml.in` uses
`@DEFDISABLEGUESTEMPTYDIR@`, tell CAA upstream, and drop the drop-in once a
Kata release carries it.

Verify: `tests/check-chart-defaults.sh` passes; a CC model pod with an
emptyDir starts with its genpolicy policy.

## Closed without change

### C1. Remote-handler drop-in on containerd 1.7

- Review: [r4222327697](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327697)

On containerd 1.7, an imported file replaces the whole CRI plugin section,
which would wipe the node's CRI config. Not applicable: CAA workers run
containerd 2.x, which merges imports. On dev (2026-10-09) both `caa-workers`
nodes run containerd 2.1.9, and `containerd config dump` keeps the node's
sandbox image, CNI paths and `discard_unpacked_layers` alongside the
kata-remote runtimes.

Re-check if CAA is ever scheduled on a node pool with containerd older than
2.0.

## Done

### D1. Workflow token permissions and pin comments

- Fixed in: `cohere-v0.21.1`, patch `ci: build, smoke test and deploy Cohere PodVM images`
- Review: [r4222327773](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327773),
  [r4222327778](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327778),
  and the zizmor alerts on PR #100

Token permissions are granted per job (`permissions: {}` at workflow level),
the baselines GitHub App token is limited to `permission-contents: read`, GCP
deploys are serialized per image tag, and action pin comments name full
releases. On `cohere-v0.23.0` the Cohere workflows use the same action pins as
upstream v0.23.

Verify after each upgrade: `zizmor --persona auditor` reports no findings on
the Cohere workflows and `.github/actions/install-oras`. zizmor must be 1.25
or newer to parse the `$/` self-repository syntax.

### D2. oras downloads were not checksum-verified

- Fixed in: `cohere-v0.21.1`, patch `ci: build, smoke test and deploy Cohere PodVM images`
- Source: Cursor security review on PR #100 (medium)

`build-podvm-cohere.yaml` (meta and build), `deploy-gcp-cohere.yaml` and
`smoke-gcp-tdx.yaml` downloaded the oras release tarball and ran it without a
checksum. oras release assets are mutable, and oras produces the digest the
build attests and pulls the image the deploy and smoke jobs publish. On
`cohere-v0.23.0` every install goes through `.github/actions/install-oras`,
which checks the tarball against a pinned SHA-256.

Verify after each upgrade, and whenever `tools.oras` changes in
`versions.yaml`: the Cohere workflows install oras only through that action,
and its pinned hash matches `oras_<version>_checksums.txt` for that version. A
version bump without a hash update fails the job.

### D3. Deploy workflows refuse images built with a provenance override

- Fixed in: `cohere-v0.22.0`, patch `ci: build, smoke test and deploy Cohere PodVM images`
- Review: [r4233674912](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4233674912)
- Still open on `cohere-v0.21.1` (backport only if deploys run from it)

A dev build can accept guest-components artifacts from one extra branch with
`provenance_extra_ref`. The build records the value it used in
`measurements.json` (empty when unused), and `deploy-gcp-cohere` and
`deploy-azure-cohere` refuse an artifact that lacks the field or has a
non-empty value, so a later, separate deploy dispatch can't publish it.

Verify after each upgrade: a deploy dispatch for an artifact built with a
non-empty `provenance_extra_ref` fails at the measurements check.

### D4. govulncheck pin and lint ordering (old F7)

- Fixed in: `cohere-v0.23.0`, by dropping `ci: pin govulncheck to v1.7.0 for Go 1.25`
- Review: [r4222327788](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327788)

Upstream v0.23 builds with Go 1.26.7, so `govulncheck@latest` installs again
and the pin patch is gone. Still open on `cohere-v0.21.1` and `cohere-v0.22.0`.

Verify after each upgrade: `lint.yaml` installs `govulncheck@latest` and the
branch Go version is 1.26 or newer.

### D5. afterburn build replaced by upstream azure-ready (old F4)

- Fixed in: `cohere-v0.23.0`, patch `podvm: Ubuntu image with NVIDIA GPU ...`
- Review: [r4222327705](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327705)

Upstream v0.23 reports Azure provisioning completion with its own
`azure-ready` tool and unit, so the patch no longer builds afterburn from
source. Still open on `cohere-v0.21.1` and `cohere-v0.22.0`.

Verify after each upgrade: an Azure peer pod VM reaches `Succeeded`, and
`journalctl -u azure-ready` on it shows the Ready report.

### D6. Annotation precedence comment and dead test (old F5)

- Fixed in: `cohere-v0.23.0`, patch `adaptor: allow operator-approved per-pod cloud overrides`
- Review: [r4222327760](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327760)

The comment now says only one key of each GCP/Azure pair can be allowlisted,
because startup validation rejects the other cloud's keys, and the test that
allowlisted both clouds' keys is gone.

Verify after each upgrade: `ValidateAllowedCloudConfigAnnotations` still
rejects keys for another cloud (`go test ./pkg/util/`).

### D7. Stats timeout and the first dial (old F6)

- Fixed in: `cohere-v0.23.0`, patch `adaptor: bound agent stats RPCs`
- Review: [r4222327762](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327762)

Documented rather than changed: the agent proxy calls `Connect` before it
serves any RPC (`proxy.go` `Start`), and that dial is bounded by
`PROXY_TIMEOUT`, so the stats RPCs only ever see an established client. The
comment now also lists `GetVolumeStats`.

Verify after each upgrade: `agentProxy.Start` still connects before
registering the TTRPC services.

### D8. Pod-controlled zone overrides are validated (old H4)

- Fixed in: `cohere-v0.23.0`, patch `adaptor: allow operator-approved per-pod cloud overrides`
- Review: [r4222327749](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327749)

`gcp_zone` must match a GCP zone name and stay in the subnet region, and
`azure_zone` must be 1, 2 or 3. The same patch caps `azure_root_volume_size`
at 4095 GB, because an unchecked int32 conversion let a pod shrink the disk,
and stops a pod from turning spot off when the operator enables it.
`gcp_disk_type` is still only checked by GCP.

Verify after each upgrade: `go test ./gcp/ ./azure/` in `src/cloud-providers`.

### D9. GKE node fix and gcp command are scoped to GCP (old H7, in part)

- Fixed in: `cohere-v0.23.0`, patches `chart: Cohere defaults, ...` and
  `chart: support multiple peer pod providers`
- Review: [r4233162107](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4233162107)

`gkeNodeFix.enabled` now defaults to on only when a GCP CAA is deployed, and
the CAA command runs `cloud-api-adaptor gcp` only for the gcp provider; every
other provider uses `entrypoint.sh` again. Before, an Azure install rendered
`cloud-api-adaptor gcp` and the GKE-only node fix.

Still open as H7: on GKE the fix runs on every node unless `nodeSelector` is
set.

Verify after each upgrade: `tests/check-chart-defaults.sh` and
`tests/check-multi-provider.sh` pass (`make static-helm-check`).

### D10. Cohere branches publish, upstream release.yaml does not

- Fixed in: `cohere-v0.23.0`, patches `ci: publish Cohere CAA images and chart`
  and `ci: build, smoke test and deploy Cohere PodVM images`

Publish, release and PodVM workflows only triggered on `cohere`, so pushes and
releases on `cohere-v*` branches were skipped or built as dev images with a
30-day TTL. They now run for `cohere` and `cohere-v*`, with per-branch
floating tags (`latest-cohere-v0-23-0`). Upstream's `release.yaml` ran on every
Cohere release and failed on its quay and multi-arch jobs; it now only runs in
`confidential-containers`.

Verify after each upgrade: a push to the version branch runs
`publish-cohere.yaml` and `build-podvm-cohere.yaml` with class `cohere`; a
Cohere release runs no `release.yaml` jobs.
