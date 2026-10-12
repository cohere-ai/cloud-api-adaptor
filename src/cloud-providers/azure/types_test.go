// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package azure

import (
	"fmt"
	"strings"
	"testing"

	armcompute "github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v4"
	"golang.org/x/crypto/ssh"
)

func TestAzureMasking(t *testing.T) {
	toBeRedacted := map[string]string{
		"client id":     "a client id",
		"tenant id":     "a tenant id",
		"client secret": "a client secret",
	}
	region := "a region"

	cloudCfg := Config{
		ClientID:     toBeRedacted["client id"],
		TenantID:     toBeRedacted["tenant id"],
		ClientSecret: toBeRedacted["client secret"],
		Region:       region,
	}

	checkLine := func(verb string) {
		logline := fmt.Sprintf(verb, cloudCfg.Redact())
		for k, v := range toBeRedacted {
			if strings.Contains(logline, v) {
				t.Errorf("For verb %s: %s contains the %s: %s", verb, logline, k, v)
			}
		}
		if !strings.Contains(logline, region) {
			t.Errorf("For verb %s: %s doesn't contain the region name: %s", verb, logline, region)
		}
	}

	checkLine("%v")
	checkLine("%s")
}

func TestGenerateSSHKeyPair(t *testing.T) {
	publicKeyBytes, err := generateSSHPublicKey()
	if err != nil {
		t.Fatalf("Failed to generate SSH key pair: %v", err)
	}

	if len(publicKeyBytes) == 0 {
		t.Error("Generated public key bytes are empty")
	}

	_, _, _, _, err = ssh.ParseAuthorizedKey(publicKeyBytes)
	if err != nil {
		t.Errorf("Failed to parse generated public key: %v", err)
	}
}

func TestApplySpotConfig(t *testing.T) {
	parameters := &armcompute.VirtualMachine{Properties: &armcompute.VirtualMachineProperties{}}
	applySpotConfig(parameters, true)

	if parameters.Properties.Priority == nil ||
		*parameters.Properties.Priority != armcompute.VirtualMachinePriorityTypesSpot {
		t.Fatalf("spot priority was not configured: %v", parameters.Properties.Priority)
	}
	if parameters.Properties.EvictionPolicy == nil ||
		*parameters.Properties.EvictionPolicy != armcompute.VirtualMachineEvictionPolicyTypesDelete {
		t.Fatalf("spot eviction policy was not configured: %v", parameters.Properties.EvictionPolicy)
	}
}

func TestGetVMParametersAppliesOverrides(t *testing.T) {
	p := &azureProvider{
		serviceConfig: &Config{
			SSHUserName:     "peerpod",
			Region:          "eastus2",
			SubnetID:        "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/peerpod",
			SecurityGroupID: "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg",
			DisableCVM:      true,
		},
	}

	vm, err := p.getVMParameters(
		"Standard_DC2as_v5",
		"disk",
		"#cloud-config\n",
		[]byte("ssh-rsa AAAA"),
		"vm-name",
		"nic-name",
		"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/images/img",
		"2",
		true, // public IP
		150,
		map[string]string{"env": "test"},
	)
	if err != nil {
		t.Fatalf("getVMParameters: %v", err)
	}

	if *vm.Location != "eastus2" {
		t.Fatalf("Location = %q, want eastus2", *vm.Location)
	}
	if len(vm.Zones) != 1 || *vm.Zones[0] != "2" {
		t.Fatalf("Zones = %v, want [2]", vm.Zones)
	}
	// Upstream v0.23 defaults DisableCVM=true to a TrustedLaunch VM.
	if sp := vm.Properties.SecurityProfile; sp == nil || sp.SecurityType == nil ||
		*sp.SecurityType != armcompute.SecurityTypesTrustedLaunch {
		t.Fatalf("expected TrustedLaunch SecurityProfile when DisableCVM=true, got %+v", sp)
	}
	if vm.Properties.StorageProfile.OSDisk.DiskSizeGB == nil || *vm.Properties.StorageProfile.OSDisk.DiskSizeGB != 150 {
		t.Fatalf("DiskSizeGB = %v, want 150", vm.Properties.StorageProfile.OSDisk.DiskSizeGB)
	}
	if vm.Tags["env"] == nil || *vm.Tags["env"] != "test" {
		t.Fatalf("Tags = %v, want env=test", vm.Tags)
	}
	nic := vm.Properties.NetworkProfile.NetworkInterfaceConfigurations[0]
	if *nic.Properties.IPConfigurations[0].Properties.Subnet.ID != p.serviceConfig.SubnetID {
		t.Fatalf("unexpected subnet: %s", *nic.Properties.IPConfigurations[0].Properties.Subnet.ID)
	}
	if nic.Properties.IPConfigurations[0].Properties.PublicIPAddressConfiguration == nil {
		t.Fatal("expected public IP configuration")
	}
	if nic.Properties.NetworkSecurityGroup == nil {
		t.Fatal("expected NSG on NIC")
	}
}

func TestGetVMParametersRejectsOversizedRootVolume(t *testing.T) {
	p := &azureProvider{
		serviceConfig: &Config{
			SSHUserName: "peerpod",
			Region:      "eastus2",
			SubnetID:    "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/peerpod",
		},
	}

	// 2^32+10 GB would wrap to a 10 GB disk if cast to int32 unchecked,
	// letting a pod annotation shrink the operator's root volume.
	for _, size := range []int64{maxOSDiskSizeGB + 1, 1<<32 + 10} {
		_, err := p.getVMParameters(
			"Standard_DC2as_v5", "disk", "#cloud-config\n", []byte("ssh-rsa AAAA"),
			"vm-name", "nic-name",
			"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/images/img",
			"", false, size, nil,
		)
		if err == nil {
			t.Fatalf("getVMParameters accepted root volume size %d GB", size)
		}
	}

	vm, err := p.getVMParameters(
		"Standard_DC2as_v5", "disk", "#cloud-config\n", []byte("ssh-rsa AAAA"),
		"vm-name", "nic-name",
		"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/images/img",
		"", false, maxOSDiskSizeGB, nil,
	)
	if err != nil {
		t.Fatalf("getVMParameters rejected the maximum root volume size: %v", err)
	}
	if got := *vm.Properties.StorageProfile.OSDisk.DiskSizeGB; got != maxOSDiskSizeGB {
		t.Fatalf("DiskSizeGB = %d, want %d", got, maxOSDiskSizeGB)
	}
}

func TestValidateZoneOverride(t *testing.T) {
	for _, zone := range []string{"1", "2", "3"} {
		if err := validateZoneOverride(zone); err != nil {
			t.Errorf("validateZoneOverride(%q) = %v, want nil", zone, err)
		}
	}
	for _, zone := range []string{"0", "4", "12", "eastus2-1", "1/foo"} {
		if err := validateZoneOverride(zone); err == nil {
			t.Errorf("validateZoneOverride(%q) = nil, want error", zone)
		}
	}
}
