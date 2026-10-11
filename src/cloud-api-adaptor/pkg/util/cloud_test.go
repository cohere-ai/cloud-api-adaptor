package util

import (
	"strings"
	"testing"

	hypannotations "github.com/kata-containers/kata-containers/src/runtime/virtcontainers/pkg/annotations"
)

func allCloudConfigAnnotations() string {
	keys := make([]string, 0, len(cloudConfigAnnotationKeys))
	for key := range cloudConfigAnnotationKeys {
		keys = append(keys, key)
	}
	return strings.Join(keys, ",")
}

func TestValidateAllowedCloudConfigAnnotations(t *testing.T) {
	tests := []struct {
		name          string
		cloudProvider string
		allowed       string
		wantErr       bool
	}{
		{name: "empty", cloudProvider: "gcp"},
		{name: "supported", cloudProvider: "gcp", allowed: GCPZoneAnnotation + "," + UseSpotAnnotation},
		{name: "wrong provider", cloudProvider: "aws", allowed: GCPZoneAnnotation, wantErr: true},
		{name: "unknown", cloudProvider: "gcp", allowed: "io.katacontainers.config.hypervisor.typo", wantErr: true},
		{name: "blocked", cloudProvider: "gcp", allowed: GCPDisableCVMAnnotation, wantErr: true},
		{name: "TEE override blocked", cloudProvider: "gcp", allowed: GCPConfidentialTypeAnnotation, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := ValidateAllowedCloudConfigAnnotations(tt.cloudProvider, tt.allowed); (err != nil) != tt.wantErr {
				t.Fatalf("ValidateAllowedCloudConfigAnnotations() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestGetPodvmResourcesFromAnnotation(t *testing.T) {
	type args struct {
		annotations map[string]string
	}
	tests := []struct {
		name  string
		args  args
		want  int64
		want1 int64
		want2 int64
	}{
		// Add test cases with annotations for only vCPUs
		{
			name: "vCPUs only",
			args: args{
				annotations: map[string]string{
					hypannotations.DefaultVCPUs: "2",
				},
			},
			want:  2,
			want1: 0,
			want2: 0,
		},
		// Add test cases with annotations for only memory
		{
			name: "memory only",
			args: args{
				annotations: map[string]string{
					hypannotations.DefaultMemory: "2048",
				},
			},
			want:  0,
			want1: 2048,
			want2: 0,
		},
		// Add test cases with annotations for both vCPUs and memory
		{
			name: "vCPUs and memory",
			args: args{
				annotations: map[string]string{
					hypannotations.DefaultVCPUs:  "2",
					hypannotations.DefaultMemory: "2048",
				},
			},
			want:  2,
			want1: 2048,
			want2: 0,
		},
		// Add test cases with annotations for only GPU
		{
			name: "GPU only",
			args: args{
				annotations: map[string]string{
					hypannotations.DefaultGPUs: "1",
				},
			},
			want:  0,
			want1: 0,
			want2: 1,
		},
		// Add test cases with annotations for vCPUs, memory and GPU
		{
			name: "vCPUs, memory and GPU",
			args: args{
				annotations: map[string]string{
					hypannotations.DefaultVCPUs:  "2",
					hypannotations.DefaultMemory: "2048",
					hypannotations.DefaultGPUs:   "1",
				},
			},
			want:  2,
			want1: 2048,
			want2: 1,
		},

		// Add test cases with annotations with invalid values
		{
			name: "vCPUs and memory with invalid values",
			args: args{
				annotations: map[string]string{
					hypannotations.DefaultVCPUs:  "invalid",
					hypannotations.DefaultMemory: "invalid",
					hypannotations.DefaultGPUs:   "invalid",
				},
			},
			want:  0,
			want1: 0,
			want2: 0,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, got1, got2 := GetPodvmResourcesFromAnnotation(tt.args.annotations)
			if got != tt.want {
				t.Errorf("GetPodvmResourcesFromAnnotation() got = %v, want %v", got, tt.want)
			}
			if got1 != tt.want1 {
				t.Errorf("GetPodvmResourcesFromAnnotation() got1 = %v, want %v", got1, tt.want1)
			}
			if got2 != tt.want2 {
				t.Errorf("GetPodvmResourcesFromAnnotation() got2 = %v, want %v", got2, tt.want2)
			}
		})
	}
}

func TestGetInstanceTypeFromAnnotation(t *testing.T) {
	type args struct {
		annotations map[string]string
	}
	tests := []struct {
		name string
		args args
		want string
	}{
		// Add test cases with annotations for only instance type
		{
			name: "instance type only",
			args: args{
				annotations: map[string]string{
					hypannotations.MachineType: "t2.small",
				},
			},
			want: "t2.small",
		},
		// Add test cases with annotations for only instance type with empty value
		{
			name: "instance type only with empty value",
			args: args{
				annotations: map[string]string{
					hypannotations.MachineType: "",
				},
			},
			want: "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := GetInstanceTypeFromAnnotation(tt.args.annotations); got != tt.want {
				t.Errorf("GetInstanceTypeFromAnnotation() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetImageFromAnnotation(t *testing.T) {
	type args struct {
		annotations map[string]string
	}
	tests := []struct {
		name string
		args args
		want string
	}{
		// Add test cases with annotations for only image name
		{
			name: "image name only",
			args: args{
				annotations: map[string]string{
					hypannotations.ImagePath: "rhel9-os",
				},
			},
			want: "rhel9-os",
		},
		// Add test cases with annotations for only image name with empty value
		{
			name: "image name only with empty value",
			args: args{
				annotations: map[string]string{
					hypannotations.ImagePath: "",
				},
			},
			want: "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := GetImageFromAnnotation(tt.args.annotations); got != tt.want {
				t.Errorf("GetImageFromAnnotation() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetCloudConfigFromAnnotation(t *testing.T) {
	annotations := map[string]string{
		UseSpotAnnotation:             "true",
		GCPZoneAnnotation:             "us-central1-b",
		GCPDiskTypeAnnotation:         "hyperdisk-balanced",
		GCPDisableCVMAnnotation:       "false",
		GCPConfidentialTypeAnnotation: "SEV",
		GCPRootVolumeSizeAnnotation:   "100",
		GCPUsePublicIPAnnotation:      "true",
		GCPNetworkTagsAnnotation:      "peerpods-vm, gpu",
		GCPTagsAnnotation:             "env=dev,owner=peerpods",
		GCPInstanceTypesAnnotation:    "g4-standard-48,a3-highgpu-1g",
	}

	got := GetCloudConfigFromAnnotation(annotations, allCloudConfigAnnotations())

	if !got.UseSpot || !got.UseSpotSet {
		t.Errorf("UseSpot = %v, UseSpotSet = %v, want true, true", got.UseSpot, got.UseSpotSet)
	}
	if got.Zone != "us-central1-b" {
		t.Errorf("Zone = %q, want us-central1-b", got.Zone)
	}
	if got.DiskType != "hyperdisk-balanced" {
		t.Errorf("DiskType = %q, want hyperdisk-balanced", got.DiskType)
	}
	if got.RootVolumeSize != 100 {
		t.Errorf("RootVolumeSize = %d, want 100", got.RootVolumeSize)
	}
	if got.UsePublicIP == nil || !*got.UsePublicIP {
		t.Errorf("UsePublicIP = %v, want pointer to true", got.UsePublicIP)
	}
	if len(got.NetworkTags) != 2 || got.NetworkTags[0] != "peerpods-vm" || got.NetworkTags[1] != "gpu" {
		t.Errorf("NetworkTags = %v, want [peerpods-vm gpu]", got.NetworkTags)
	}
	if got.Tags["env"] != "dev" || got.Tags["owner"] != "peerpods" {
		t.Errorf("Tags = %v, want env=dev owner=peerpods", got.Tags)
	}
	if len(got.InstanceTypes) != 2 || got.InstanceTypes[0] != "g4-standard-48" || got.InstanceTypes[1] != "a3-highgpu-1g" {
		t.Errorf("InstanceTypes = %v, want [g4-standard-48 a3-highgpu-1g]", got.InstanceTypes)
	}
}

func TestGetCloudConfigFromAnnotationAzure(t *testing.T) {
	annotations := map[string]string{
		AzureZoneAnnotation:             "2",
		AzureDisableCVMAnnotation:       "true",
		AzureRootVolumeSizeAnnotation:   "200",
		AzureUsePublicIPAnnotation:      "false",
		AzureTagsAnnotation:             "team=cc,env=test",
		AzureInstanceSizesAnnotation:    "Standard_DC2as_v5,Standard_NCC40ads_H100_v5",
		AzureEnableSecureBootAnnotation: "true",
	}

	got := GetCloudConfigFromAnnotation(annotations, allCloudConfigAnnotations())

	if got.Zone != "2" {
		t.Errorf("Zone = %q, want 2", got.Zone)
	}
	if got.RootVolumeSize != 200 {
		t.Errorf("RootVolumeSize = %d, want 200", got.RootVolumeSize)
	}
	if got.UsePublicIP == nil || *got.UsePublicIP {
		t.Errorf("UsePublicIP = %v, want pointer to false", got.UsePublicIP)
	}
	if got.Tags["team"] != "cc" || got.Tags["env"] != "test" {
		t.Errorf("Tags = %v, want team=cc env=test", got.Tags)
	}
	if len(got.InstanceTypes) != 2 || got.InstanceTypes[0] != "Standard_DC2as_v5" {
		t.Errorf("InstanceTypes = %v, want Azure sizes", got.InstanceTypes)
	}
}

func TestGetCloudConfigFromAnnotationAzureOverridesGCP(t *testing.T) {
	annotations := map[string]string{
		GCPZoneAnnotation:             "us-central1-a",
		AzureZoneAnnotation:           "3",
		GCPDisableCVMAnnotation:       "false",
		AzureDisableCVMAnnotation:     "true",
		GCPRootVolumeSizeAnnotation:   "50",
		AzureRootVolumeSizeAnnotation: "120",
		GCPTagsAnnotation:             "cloud=gcp",
		AzureTagsAnnotation:           "cloud=azure",
		GCPInstanceTypesAnnotation:    "c3-standard-4",
		AzureInstanceSizesAnnotation:  "Standard_DC2as_v5",
	}

	got := GetCloudConfigFromAnnotation(annotations, allCloudConfigAnnotations())
	if got.Zone != "3" {
		t.Errorf("Zone = %q, want Azure zone 3", got.Zone)
	}
	if got.RootVolumeSize != 120 {
		t.Errorf("RootVolumeSize = %d, want 120", got.RootVolumeSize)
	}
	if got.Tags["cloud"] != "azure" {
		t.Errorf("Tags = %v, want cloud=azure", got.Tags)
	}
	if len(got.InstanceTypes) != 1 || got.InstanceTypes[0] != "Standard_DC2as_v5" {
		t.Errorf("InstanceTypes = %v, want [Standard_DC2as_v5]", got.InstanceTypes)
	}
}

func TestGetCloudConfigFromAnnotationRequiresAllowlist(t *testing.T) {
	annotations := map[string]string{
		GCPZoneAnnotation:        "us-central1-b",
		GCPDisableCVMAnnotation:  "true",
		GCPUsePublicIPAnnotation: "true",
		GCPNetworkTagsAnnotation: "peerpods-vm",
	}

	got := GetCloudConfigFromAnnotation(annotations, GCPZoneAnnotation+","+GCPDisableCVMAnnotation)

	if got.Zone != "us-central1-b" {
		t.Errorf("Zone = %q, want us-central1-b", got.Zone)
	}
	if got.UsePublicIP != nil {
		t.Errorf("UsePublicIP = %v, want nil", got.UsePublicIP)
	}
	if len(got.NetworkTags) != 0 {
		t.Errorf("NetworkTags = %v, want none", got.NetworkTags)
	}
}

func TestGetCloudConfigFromAnnotationIgnoresInvalidValues(t *testing.T) {
	annotations := map[string]string{
		UseSpotAnnotation:           "invalid",
		GCPDisableCVMAnnotation:     "invalid",
		GCPRootVolumeSizeAnnotation: "invalid",
		GCPUsePublicIPAnnotation:    "invalid",
		AzureDisableCVMAnnotation:   "invalid",
		AzureUsePublicIPAnnotation:  "invalid",
	}

	got := GetCloudConfigFromAnnotation(annotations, allCloudConfigAnnotations())

	if got.UseSpotSet {
		t.Errorf("UseSpotSet = %v, want false", got.UseSpotSet)
	}
	if got.RootVolumeSize != 0 {
		t.Errorf("RootVolumeSize = %d, want 0", got.RootVolumeSize)
	}
	if got.UsePublicIP != nil {
		t.Errorf("UsePublicIP = %v, want nil", got.UsePublicIP)
	}
}
