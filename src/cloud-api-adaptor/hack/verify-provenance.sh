#!/bin/bash

# Verify Github's attestation reports. Meant to verify binaries built
# by upstream projects (kata-containers and guest-components).
#
# GH cli is used to verify.
#
# Asserts on the claims are:
# - Triggered by push or workflow_dispatch on an approved branch
# - Built on the given repository
# - The gh action workflow is matching the given digest
# - The code is matching the given digest
#
# -g will fetch attestation via gh cli, this requires GH_TOKEN to be
# set. By default the attestation will be retrieved by walking the OCI
# manifest

set -euo pipefail

usage() {
	echo "Usage: $0 "
	echo "  -a <oci-artifact w/ sha256 digest>"
	echo "  -d <expected git sha1 from which the artifact was built>"
	echo "  -r <repository on which the artifact was built>"
	echo "  [-g] (optional. fetch attestation using github api)"
	echo "  [-s] (optional. deny attestations produced on self-hosted runners)"
	exit 1
}

oci_artifact=""
expected_digest=""
repository=""
github="0"
assert_runner="0"

# Parse options using getopts
while getopts ":a:d:r:gs" opt; do
	case "${opt}" in
	a)
		oci_artifact="${OPTARG}"
		;;
	d)
		expected_digest="${OPTARG}"
		;;
	r)
		repository="${OPTARG}"
		;;
	g)
		github="1"
		;;
	s)
		assert_runner="1"
		;;
	*)
		usage
		;;
	esac
done

# Check if all required arguments are provided
if [ -z "${oci_artifact}" ] || [ -z "${expected_digest}" ] || [ -z "${repository}" ]; then
	usage
fi

if [[ "$oci_artifact" =~ @sha256:[a-fA-F0-9]{32}$ ]]; then
	echo "The OCI artifact should be specified using its digest: my-repo.io/my-image@sha256:abc..."
	exit 1
fi

cleanup() {
    rm -f "$attestation_bundle"
}
trap cleanup EXIT SIGINT SIGTERM

# Convention by gh cli
attestation_bundle="${oci_artifact#*@}.jsonl"

if [ "$github" != "1" ]; then
	attestation_manifest_digest=$(oras discover "$oci_artifact" --format json | jq -r '
		.manifests[]
		| select(.artifactType | test("sigstore.bundle.*json"))
		| .digest
	')

	oci_base="${oci_artifact%@*}"
	attestation_manifest="${oci_base}@${attestation_manifest_digest}"

	attestation_bundle_digest=$(oras manifest fetch "$attestation_manifest" --format json | jq -r '
		.content.layers[]
		| select(.mediaType | test("sigstore.bundle.*json"))
		| .digest
	')

	attestation_image="${oci_base}@${attestation_bundle_digest}"

	oras blob fetch --no-tty "$attestation_image" --output "$attestation_bundle"
else
	gh attestation download "oci://${oci_artifact}" -R "$repository"
fi

claims=$(
	gh attestation verify "oci://${oci_artifact}" \
		-b "$attestation_bundle" \
		-R "$repository" \
		--format json \
		-q '.[].verificationResult.signature.certificate
		| {
			digest:          .sourceRepositoryDigest,
			workflowDigest:  .githubWorkflowSHA,
			workflowTrigger: .githubWorkflowTrigger,
			workflowRef:     .githubWorkflowRef,
			runner:          .runnerEnvironment,
		}'
)

digest=$(echo "$claims" | jq -r '.digest')
workflow_digest=$(echo "$claims" | jq -r '.workflowDigest')
workflow_trigger=$(echo "$claims" | jq -r '.workflowTrigger')
workflow_ref=$(echo "$claims" | jq -r '.workflowRef')
runner=$(echo "$claims" | jq -r '.runner')

verification_failed=""

if [ "$digest" != "$expected_digest" ]; then
	echo "Source code digest mismatch: expected $expected_digest, got $digest"
	verification_failed="1"
fi

if [ "$workflow_digest" != "$digest" ]; then
	echo "Workflow digest mismatch: expected $expected_digest, got $workflow_digest"
	verification_failed="1"
fi

if [ "$workflow_trigger" != "push" ] && [ "$workflow_trigger" != "workflow_dispatch" ]; then
	echo "Workflow trigger mismatch: expected push or workflow_dispatch, got $workflow_trigger"
	verification_failed="1"
fi

# Accepted refs: upstream main for repositories such as kata-containers. The
# Cohere guest-components fork is trusted only from its legacy cohere branch and
# release branches explicitly approved by this verifier.
# PROVENANCE_EXTRA_REF lets a non-deploying dev build also accept one
# guest-components ref, e.g. an upgrade branch under review. CI release and
# deployed workflow builds never set it.
readonly COHERE_GC_REPO="cohere-ai/guest-components"
readonly COHERE_GC_RELEASE_REFS=("refs/heads/cohere-v0.21.0" "refs/heads/cohere-v0.22.0")
ref_allowed=""
if [ "$repository" = "$COHERE_GC_REPO" ]; then
	if [ "$workflow_ref" = "refs/heads/cohere" ]; then
		ref_allowed="1"
	else
		for allowed_ref in "${COHERE_GC_RELEASE_REFS[@]}"; do
			if [ "$workflow_ref" = "$allowed_ref" ]; then
				ref_allowed="1"
				break
			fi
		done
	fi
elif [ "$workflow_ref" = "refs/heads/main" ]; then
	ref_allowed="1"
fi
if [ "$repository" = "$COHERE_GC_REPO" ] && [ -n "${PROVENANCE_EXTRA_REF:-}" ] && [ "$workflow_ref" = "$PROVENANCE_EXTRA_REF" ]; then
	echo "WARNING: accepting guest-components ref $workflow_ref via PROVENANCE_EXTRA_REF (non-deploying dev builds only)"
	ref_allowed="1"
fi
if [ -z "$ref_allowed" ]; then
	if [ "$repository" = "$COHERE_GC_REPO" ]; then
		echo "Workflow ref mismatch: expected refs/heads/cohere or one of: ${COHERE_GC_RELEASE_REFS[*]}, got $workflow_ref"
	else
		echo "Workflow ref mismatch: expected refs/heads/main for $repository, got $workflow_ref"
	fi
	verification_failed="1"
fi

if [ "$assert_runner" == "1" ] && [ "$runner" != "github-hosted" ]; then
	echo "Runner mismatch: expected github-hosted, got $runner"
	verification_failed="1"
fi

if [ "$verification_failed" != "" ]; then
	echo "Verification failed"
	exit 1
fi

echo "Verification passed"
