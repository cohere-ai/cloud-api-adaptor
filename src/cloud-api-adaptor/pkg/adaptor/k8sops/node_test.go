package k8sops

import "testing"

func TestPodVMExtendedResourceNameDefault(t *testing.T) {
	t.Setenv("POD_VM_EXTENDED_RESOURCE", "")

	if got := podVMExtendedResourceName(); got != defaultPodVMExtendedResource {
		t.Fatalf("expected default resource %q, got %q", defaultPodVMExtendedResource, got)
	}
}

func TestPodVMExtendedResourceNameOverride(t *testing.T) {
	const resourceName = "kata.peerpods.io/vm-gcp"
	t.Setenv("POD_VM_EXTENDED_RESOURCE", resourceName)

	if got := podVMExtendedResourceName(); got != resourceName {
		t.Fatalf("expected overridden resource %q, got %q", resourceName, got)
	}
}

func TestNewJSONPatchEscapesExtendedResourceName(t *testing.T) {
	patch := newJSONPatch("add", "/status/capacity", "kata.peerpods.io/vm-gcp", "10")

	if got, want := patch.Path, "/status/capacity/kata.peerpods.io~1vm-gcp"; got != want {
		t.Fatalf("expected escaped path %q, got %q", want, got)
	}
}

func TestOwnerAnnotationKeyDefault(t *testing.T) {
	t.Setenv("POD_VM_EXTENDED_RESOURCE", "")

	if got := ownerAnnotationKey(); got != OwnerAnnotation {
		t.Fatalf("expected default owner annotation %q, got %q", OwnerAnnotation, got)
	}
}

func TestOwnerAnnotationKeyPerProvider(t *testing.T) {
	t.Setenv("POD_VM_EXTENDED_RESOURCE", "kata.peerpods.io/vm-gcp")
	gcp := ownerAnnotationKey()
	t.Setenv("POD_VM_EXTENDED_RESOURCE", "kata.peerpods.io/vm-azure")
	azure := ownerAnnotationKey()

	if gcp != "kata.peerpods.io/caa-owner-vm-gcp" {
		t.Fatalf("unexpected gcp owner annotation %q", gcp)
	}
	if gcp == azure {
		t.Fatalf("providers sharing a node must use distinct owner annotations, both got %q", gcp)
	}
}
