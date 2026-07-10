package util

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/confidential-containers/cloud-api-adaptor/src/cloud-api-adaptor/pkg/initdata"
	cri "github.com/containerd/containerd/pkg/cri/annotations"
	hypannotations "github.com/kata-containers/kata-containers/src/runtime/virtcontainers/pkg/annotations"
)

const (
	GCPZoneAnnotation             = "io.katacontainers.config.hypervisor.gcp_zone"
	GCPDiskTypeAnnotation         = "io.katacontainers.config.hypervisor.gcp_disk_type"
	GCPDisableCVMAnnotation       = "io.katacontainers.config.hypervisor.gcp_disable_cvm"
	GCPConfidentialTypeAnnotation = "io.katacontainers.config.hypervisor.gcp_confidential_type"
	GCPRootVolumeSizeAnnotation   = "io.katacontainers.config.hypervisor.gcp_root_volume_size"
	GCPUsePublicIPAnnotation      = "io.katacontainers.config.hypervisor.gcp_use_public_ip"
	GCPNetworkTagsAnnotation      = "io.katacontainers.config.hypervisor.gcp_network_tags"
	GCPTagsAnnotation             = "io.katacontainers.config.hypervisor.gcp_tags"
	GCPInstanceTypesAnnotation    = "io.katacontainers.config.hypervisor.gcp_instance_types"

	AzureZoneAnnotation             = "io.katacontainers.config.hypervisor.azure_zone"
	AzureDisableCVMAnnotation       = "io.katacontainers.config.hypervisor.azure_disable_cvm"
	AzureRootVolumeSizeAnnotation   = "io.katacontainers.config.hypervisor.azure_root_volume_size"
	AzureUsePublicIPAnnotation      = "io.katacontainers.config.hypervisor.azure_use_public_ip"
	AzureTagsAnnotation             = "io.katacontainers.config.hypervisor.azure_tags"
	AzureInstanceSizesAnnotation    = "io.katacontainers.config.hypervisor.azure_instance_sizes"
	AzureEnableSecureBootAnnotation = "io.katacontainers.config.hypervisor.azure_enable_secure_boot"

	UseSpotAnnotation = "io.katacontainers.config.hypervisor.use_spot"
)

// CloudConfigAnnotations holds per-pod VM overrides from annotations.
// Account/network placement (subscription, project, RG, VNet/subnet, NSG)
// comes only from CAA ConfigMap/env — not from pod annotations.
type CloudConfigAnnotations struct {
	UseSpot          bool
	UseSpotSet       bool
	Zone             string
	DiskType         string
	DisableCVM       *bool
	ConfidentialType string
	RootVolumeSize   int64
	UsePublicIP      *bool
	NetworkTags      []string
	Tags             map[string]string
	InstanceTypes    []string
	EnableSecureBoot *bool
}

func GetPodName(annotations map[string]string) string {

	sandboxName := annotations[cri.SandboxName]

	// cri-o stores the sandbox name in the form of k8s_<pod name>_<namespace>_<uid>_0
	// Extract the pod name from it.
	if tmp := strings.Split(sandboxName, "_"); len(tmp) > 1 && tmp[0] == "k8s" {
		return tmp[1]
	}

	return sandboxName
}

func GetPodNamespace(annotations map[string]string) string {

	return annotations[cri.SandboxNamespace]
}

// Method to get instance type from annotation
func GetInstanceTypeFromAnnotation(annotations map[string]string) string {
	// The machine_type annotation in Kata refers to VM type
	// For example machine_type for Kata/Qemu refers to pc, q35, microvm etc.
	// We use the same annotation for Kata/remote to refer to cloud instance type (flavor)
	return annotations[hypannotations.MachineType]
}

// Method to get image from annotation
func GetImageFromAnnotation(annotations map[string]string) string {
	// The image annotation in Kata refers to image path
	// For example image for Kata/Qemu refers to /hypervisor/image.img etc.
	// We use the same annotation for Kata/remote to refer to image name
	return annotations[hypannotations.ImagePath]
}

// Method to get spot instance preference from annotation
func GetUseSpotFromAnnotation(annotations map[string]string) bool {
	useSpot, ok := GetBoolAnnotation(annotations, UseSpotAnnotation)
	if !ok {
		return false
	}
	return useSpot
}

func GetUseSpotFromAnnotationWithDefault(annotations map[string]string) (bool, bool) {
	return GetBoolAnnotation(annotations, UseSpotAnnotation)
}

func GetBoolAnnotation(annotations map[string]string, key string) (bool, bool) {
	val := annotations[key]
	if val == "" {
		return false, false
	}
	parsed, err := strconv.ParseBool(val)
	if err != nil {
		fmt.Printf("Error converting %s to bool. Ignoring annotation: %v\n", key, err)
		return false, false
	}
	return parsed, true
}

func getInt64Annotation(annotations map[string]string, key string) int64 {
	val := annotations[key]
	if val == "" {
		return 0
	}
	parsed, err := strconv.ParseInt(val, 10, 64)
	if err != nil {
		fmt.Printf("Error converting %s to int64. Ignoring annotation: %v\n", key, err)
		return 0
	}
	return parsed
}

func getStringListAnnotation(annotations map[string]string, key string) []string {
	val := annotations[key]
	if val == "" {
		return nil
	}

	items := strings.Split(val, ",")
	trimmed := make([]string, 0, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item != "" {
			trimmed = append(trimmed, item)
		}
	}
	return trimmed
}

func getStringMapAnnotation(annotations map[string]string, key string) map[string]string {
	val := annotations[key]
	if val == "" {
		return nil
	}

	result := map[string]string{}
	for _, pair := range strings.Split(val, ",") {
		keyValue := strings.SplitN(pair, "=", 2)
		if len(keyValue) != 2 {
			fmt.Printf("Error converting %s to key-value map. Ignoring invalid pair %q\n", key, pair)
			continue
		}
		mapKey := strings.TrimSpace(keyValue[0])
		mapValue := strings.TrimSpace(keyValue[1])
		if mapKey != "" {
			result[mapKey] = mapValue
		}
	}

	if len(result) == 0 {
		return nil
	}
	return result
}

func GetCloudConfigFromAnnotation(annotations map[string]string) CloudConfigAnnotations {
	useSpot, useSpotSet := GetBoolAnnotation(annotations, UseSpotAnnotation)

	// Prefer cloud-specific keys when both GCP and Azure variants are present.
	disableCVM, disableCVMSet := GetBoolAnnotation(annotations, GCPDisableCVMAnnotation)
	if azureDisableCVM, ok := GetBoolAnnotation(annotations, AzureDisableCVMAnnotation); ok {
		disableCVM, disableCVMSet = azureDisableCVM, true
	}
	usePublicIP, usePublicIPSet := GetBoolAnnotation(annotations, GCPUsePublicIPAnnotation)
	if azureUsePublicIP, ok := GetBoolAnnotation(annotations, AzureUsePublicIPAnnotation); ok {
		usePublicIP, usePublicIPSet = azureUsePublicIP, true
	}
	enableSecureBoot, enableSecureBootSet := GetBoolAnnotation(annotations, AzureEnableSecureBootAnnotation)

	zone := annotations[GCPZoneAnnotation]
	if annotations[AzureZoneAnnotation] != "" {
		zone = annotations[AzureZoneAnnotation]
	}
	rootVolumeSize := getInt64Annotation(annotations, GCPRootVolumeSizeAnnotation)
	if azureRoot := getInt64Annotation(annotations, AzureRootVolumeSizeAnnotation); azureRoot > 0 {
		rootVolumeSize = azureRoot
	}
	tags := getStringMapAnnotation(annotations, GCPTagsAnnotation)
	if azureTags := getStringMapAnnotation(annotations, AzureTagsAnnotation); len(azureTags) > 0 {
		tags = azureTags
	}
	instanceTypes := getStringListAnnotation(annotations, GCPInstanceTypesAnnotation)
	if azureSizes := getStringListAnnotation(annotations, AzureInstanceSizesAnnotation); len(azureSizes) > 0 {
		instanceTypes = azureSizes
	}

	cfg := CloudConfigAnnotations{
		UseSpot:          useSpot,
		UseSpotSet:       useSpotSet,
		Zone:             zone,
		DiskType:         annotations[GCPDiskTypeAnnotation],
		ConfidentialType: annotations[GCPConfidentialTypeAnnotation],
		RootVolumeSize:   rootVolumeSize,
		NetworkTags:      getStringListAnnotation(annotations, GCPNetworkTagsAnnotation),
		Tags:             tags,
		InstanceTypes:    instanceTypes,
	}

	if disableCVMSet {
		cfg.DisableCVM = &disableCVM
	}
	if usePublicIPSet {
		cfg.UsePublicIP = &usePublicIP
	}
	if enableSecureBootSet {
		cfg.EnableSecureBoot = &enableSecureBoot
	}

	return cfg
}

// Method to get vCPU, memory and gpus from annotations
func GetPodvmResourcesFromAnnotation(annotations map[string]string) (int64, int64, int64) {

	var vcpuInt, memoryInt, gpuInt int64
	var err error

	vcpu, ok := annotations[hypannotations.DefaultVCPUs]
	if ok {
		vcpuInt, err = strconv.ParseInt(vcpu, 10, 64)
		if err != nil {
			fmt.Printf("Error converting vcpu to int64. Defaulting to 0: %v\n", err)
			vcpuInt = 0
		}
	} else {
		vcpuInt = 0
	}

	memory, ok := annotations[hypannotations.DefaultMemory]
	if ok {
		// Use strconv.ParseInt to convert string to int64
		memoryInt, err = strconv.ParseInt(memory, 10, 64)
		if err != nil {
			fmt.Printf("Error converting memory to int64. Defaulting to 0: %v\n", err)
			memoryInt = 0
		}

	} else {
		memoryInt = 0
	}

	gpu, ok := annotations[hypannotations.DefaultGPUs]
	if ok {
		gpuInt, err = strconv.ParseInt(gpu, 10, 64)
		if err != nil {
			fmt.Printf("Error converting gpu to int64. Defaulting to 0: %v\n", err)
			gpuInt = 0
		}
	} else {
		gpuInt = 0
	}

	// Return vCPU, memory and GPU
	return vcpuInt, memoryInt, gpuInt
}

// Method to get initdata from annotation. Initdata is delivered as raw
// string by kata runtime, so we want to compress and base64 it again.
func GetInitdataFromAnnotation(annotations map[string]string) (string, error) {
	str := annotations["io.katacontainers.config.hypervisor.cc_init_data"]
	if str == "" {
		return "", nil
	}

	initdataEnc, err := initdata.Encode(str)
	if err != nil {
		return "", fmt.Errorf("failed to encode initdata: %w", err)
	}

	return initdataEnc, nil
}

// Method to check if a string exists in a slice
func Contains(slice []string, s string) bool {
	for _, item := range slice {
		if item == s {
			return true
		}
	}
	return false
}
