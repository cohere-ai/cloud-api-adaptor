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
on [PR #100](https://github.com/cohere-ai/cloud-api-adaptor/pull/100). Paths
below are the post-v0.22 locations (`podvm-mkosi/` merged into `podvm/`
upstream).

## Open: fix

### F1. RTMR3 helper delays every non-TDX boot by 30 seconds

- Patch: `podvm: Ubuntu image with NVIDIA GPU, TDX RTMR3 initdata and Azure boot`
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

- Patch: `podvm: Ubuntu image ...`
- File: `extend-rtmr3-initdata` (same as F1)
- Review: [r4222327736](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327736)

Fix: add `iflag=fullblock` to the `dd` that writes the 48-byte digest.

Verify: `grep -n 'iflag=fullblock' extend-rtmr3-initdata`; RTMR3 smoke test
still passes.

### F3. Preempted GCP spot VMs stop instead of being deleted

- Patch: `gcp: add spot VMs, network tags, opt-in public IP and peerpod-ctrl support`
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

### F4. afterburn builds without its lockfile

- Patch: `podvm: Ubuntu image ...`
- File: `src/cloud-api-adaptor/podvm/Dockerfile.podvm_binaries` (afterburn stage)
- Review: [r4222327705](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327705)

Fix: `cargo build --locked --release --bin afterburn`, so the build uses
afterburn's `Cargo.lock` instead of resolving dependencies fresh each time.

Verify: the PodVM binaries image builds; Azure peer pod reaches `Succeeded`.

### F5. Misleading comment on annotation precedence

- Patch: `adaptor: allow operator-approved per-pod cloud overrides`
- File: `src/cloud-api-adaptor/pkg/util/cloud.go` ("Prefer cloud-specific keys ...")
- Review: [r4222327760](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327760)

The code prefers Azure keys over GCP keys. That is harmless only because
startup validation rejects the other cloud's keys. Fix the comment to say so.

### F6. Stats timeout skips the first dial

- Patch: `adaptor: bound agent stats RPCs and reject cancelled CreateContainer`
- File: `src/cloud-api-adaptor/pkg/util/agentproto/redirector.go`
- Review: [r4222327762](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327762)

The timeout starts after `Connect`, and the first `Connect` dials without one,
so an unreachable VM can still stall stats until its first connection. The
comment also omits `GetVolumeStats`.

Fix: bound the first dial, or document why it can't be; add `GetVolumeStats`
to the comment.

Verify: unit test with a dialer that never connects returns within the timeout.

### F7. Lint can fail before the govulncheck pin

- Patch order: `ci: pin govulncheck to v1.7.0 for Go 1.25`
- Review: [r4222327788](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327788)

If `govulncheck@latest` fails on Go 1.25, lint fails on every patch before the
pin, which makes bisecting harder. Move the pin right after the deps patch.

Drops out if the branch's Go is 1.26 or newer (upstream v0.23 is on 1.26.7):
the pin patch itself is then removed.

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

- Patch: `podvm: Ubuntu image ...`
- File: `src/cloud-api-adaptor/podvm/Dockerfile.mkosi` (keyring download)
- Review: [r4222327713](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327713)

Fix: after download, compare `gpg --show-keys --with-colons` fingerprints
against pinned values and fail on mismatch, or commit the keyrings.

### H3. Measured UKI uses the EOL Ubuntu 24.10 systemd stub

- Patch: `podvm: Ubuntu image ...`
- Review: [r4222327719](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327719)

The v256 stub comes from 24.10 because its RTMR2 measurement matches
cvm-measure. 24.10 gets no more security updates. Move to a supported source
of a v256+ stub (for example 25.04 or newer, or a Noble backport) and
re-validate RTMR2 against cvm-measure.

### H4. Pod-controlled GCP zone and disk type are loosely validated

- Patch: `adaptor: allow operator-approved per-pod cloud overrides`
- File: `src/cloud-providers/gcp/provider.go` (zone check)
- Review: [r4222327749](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327749)

Only the region prefix of `gcp_zone` is checked, so `us-central1-a/foo` passes
and is formatted into `zones/%s/...`. `gcp_disk_type` is not validated. GCP
rejects bad values, so impact is low, but these come from pod annotations.

Fix: strict patterns, for example `^[a-z]+-[a-z]+[0-9]+-[a-z]$` for the zone
and an allowlist or `^[a-z0-9-]+$` for the disk type, with unit tests.

### H5. Deploy jobs have no protected environment

- Patch: `ci: build, smoke test and deploy Cohere PodVM images`
- Files: `deploy-gcp-cohere.yaml`, `deploy-azure-cohere.yaml`,
  `build-podvm-cohere.yaml`, `.github/zizmor.yml`
- Review: [r4222327778](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4222327778)

Deploy access rests only on the cloud-side OIDC subject conditions. Add a
protected `environment:` (required reviewers, `cohere-v*` only) to the GCP and
Azure deploy jobs, and update the GCP Workload Identity and Azure federated
credential subjects to match.

Once there is an environment, move `GH_APP_CLIENT_ID` and `GH_APP_PRIVATE_KEY`
into it and drop the `secrets-outside-env` allowance in `.github/zizmor.yml`.
Both need repository settings changes, not just code.

Verify: deploy jobs wait for environment approval; zizmor passes without the
allowance.

### H6. govulncheck fails on Go 1.25 dependencies

- Patch: `deps: ...` (first patch of the series)
- Check: `lint / govulncheck` (not required to merge)

On `cohere-v0.21.1` govulncheck reports findings in every module: Go 1.25.12
standard library (fixed in 1.25.13 or 1.26.9), `golang.org/x/net` 0.55/0.56
(fixed in 0.60), `golang.org/x/crypto` 0.52, gRPC 1.82.1 (fixed in 1.83.1),
containerd 1.7.34 (some fixed in 1.7.35/1.7.36, three CRI checkpoint issues
with no fix), and `github.com/docker/docker` 28.5.2 (no fix). The same check
failed on `cohere` and on PR #67.

Upstream v0.23.0 moves to Go 1.26.7, containerd 1.7.35 and gRPC 1.83.2, which
covers most of this. On the v0.23 branch, rerun govulncheck and list any
remaining unfixable findings in `.govulncheck-ignore.toml` with a reason each.
`hack/govulncheck.sh` reads that file from upstream v0.22.0 on.

Verify: `make govulncheck` exits 0 on the version branch.

### H7. GKE node fix runs on every node by default

- Patch: `chart: Cohere defaults, GCP workload identity and GKE node fixes`
- Files: `install/charts/peerpods/values.yaml` (`gkeNodeFix.enabled: true`,
  top-level `nodeSelector: {}`), `templates/fix-gke-node-config.yaml`
- Review: [r4233162107](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4233162107)

`gkeNodeFix` is on by default and inherits the empty top-level `nodeSelector`.
A default install runs its privileged, `hostPID` DaemonSet on every node: it
rewrites containerd and kubelet config, restarts both, and needs the GKE-only
`/home/kubernetes` host path. Our environments are safe only because their
values set `nodeSelector: {cohere.com/caa-worker: "true"}`.

Fix: default `gkeNodeFix.enabled` to `false`, and fail rendering when it is
enabled with an empty `nodeSelector`. Set it explicitly in each environment's
values before changing the default.

Verify: `helm template` with default values renders no `fix-gke-node-config`;
enabling it without a `nodeSelector` fails with a clear error;
`make static-helm-check` passes.

### H8. Deploy workflows publish images built with a provenance override

- Patch: `ci: build, smoke test and deploy Cohere PodVM images`
- Files: `deploy-gcp-cohere.yaml`, `deploy-azure-cohere.yaml`,
  `build-podvm-cohere.yaml`
- Review: [r4233674912](https://github.com/cohere-ai/cloud-api-adaptor/pull/100#discussion_r4233674912)

A dev build can accept guest-components artifacts from one extra branch with
`provenance_extra_ref`. The build refuses to deploy that image in the same
run, but `deploy-gcp-cohere` and `deploy-azure-cohere` can also be dispatched
on their own, and on `cohere-v0.21.1` they only run `gh attestation verify`.
A later dispatch can therefore publish that dev image to the GCP and Azure
galleries.

Fix: the build records `provenance_extra_ref` in `measurements.json` (empty
when unused), and both deploy workflows refuse an artifact that lacks the
field or has a non-empty value.

Already fixed on `cohere-v0.22.0`. Backport to `cohere-v0.21.1` only if
deploys run from that branch.

Verify: a deploy dispatch for an artifact built with a non-empty
`provenance_extra_ref` fails at the measurements check.

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
releases.

Verify after each upgrade: `zizmor --persona auditor` reports no findings on
`build-podvm-cohere.yaml`, `deploy-gcp-cohere.yaml`, `deploy-azure-cohere.yaml`
and `smoke-gcp-tdx.yaml`.

### D2. oras downloads were not checksum-verified

- Fixed in: `cohere-v0.21.1`, patch `ci: build, smoke test and deploy Cohere PodVM images`
- Source: Cursor security review on PR #100 (medium)

`build-podvm-cohere.yaml` (meta and build), `deploy-gcp-cohere.yaml` and
`smoke-gcp-tdx.yaml` downloaded the oras release tarball and ran it without a
checksum. oras release assets are mutable, and oras produces the digest the
build attests and pulls the image the deploy and smoke jobs publish. Every
install now checks `ORAS_SHA256`, as `deploy-azure-cohere.yaml` already did.

Verify after each upgrade, and whenever `tools.oras` changes in
`versions.yaml`: every `releases/download/v${ORAS_VERSION}` line in the four
Cohere workflows is followed by `sha256sum -c` against `ORAS_SHA256`, and the
pinned hash matches `oras_<version>_checksums.txt` for that version. A version
bump without a hash update fails the job, because `sha256sum` cannot find the
renamed file.
