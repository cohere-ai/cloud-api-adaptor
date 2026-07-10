// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package azure

import (
	"fmt"
	"strings"
	"testing"

	provider "github.com/confidential-containers/cloud-api-adaptor/src/cloud-providers"
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

func TestChooseHelpersPreferAnnotation(t *testing.T) {
	if got := chooseString("from-annotation", "from-config"); got != "from-annotation" {
		t.Fatalf("chooseString = %q, want from-annotation", got)
	}
	if got := chooseString("", "from-config"); got != "from-config" {
		t.Fatalf("chooseString empty = %q, want from-config", got)
	}

	trueVal := true
	if got := chooseBool(&trueVal, false); !got {
		t.Fatal("chooseBool should prefer annotation true")
	}
	if got := chooseBool(nil, true); !got {
		t.Fatal("chooseBool nil should keep default true")
	}

	if got := chooseInt64(80, 10); got != 80 {
		t.Fatalf("chooseInt64 = %d, want 80", got)
	}
	if got := chooseInt64(0, 10); got != 10 {
		t.Fatalf("chooseInt64 zero = %d, want 10", got)
	}

	tags := chooseTags(map[string]string{"a": "1"}, provider.KeyValueFlag{"a": "0", "b": "2"})
	if tags["a"] != "1" || len(tags) != 1 {
		t.Fatalf("chooseTags annotation = %v", tags)
	}
	tags = chooseTags(nil, provider.KeyValueFlag{"b": "2"})
	if tags["b"] != "2" {
		t.Fatalf("chooseTags default = %v", tags)
	}
}

func TestGetVMParametersAppliesOverrides(t *testing.T) {
	p := &azureProvider{
		serviceConfig: &Config{
			SSHUserName: "peerpod",
			Region:      "westus",
			SubnetID:    "/default/subnet",
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
		"eastus2",
		"2",
		"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/override",
		"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg",
		true,  // disable CVM
		false, // secure boot
		true,  // public IP
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
	if vm.Properties.SecurityProfile != nil {
		t.Fatal("expected nil SecurityProfile when DisableCVM=true")
	}
	if vm.Properties.StorageProfile.OSDisk.DiskSizeGB == nil || *vm.Properties.StorageProfile.OSDisk.DiskSizeGB != 150 {
		t.Fatalf("DiskSizeGB = %v, want 150", vm.Properties.StorageProfile.OSDisk.DiskSizeGB)
	}
	if vm.Tags["env"] == nil || *vm.Tags["env"] != "test" {
		t.Fatalf("Tags = %v, want env=test", vm.Tags)
	}
	nic := vm.Properties.NetworkProfile.NetworkInterfaceConfigurations[0]
	if *nic.Properties.IPConfigurations[0].Properties.Subnet.ID != "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/override" {
		t.Fatalf("unexpected subnet: %s", *nic.Properties.IPConfigurations[0].Properties.Subnet.ID)
	}
	if nic.Properties.IPConfigurations[0].Properties.PublicIPAddressConfiguration == nil {
		t.Fatal("expected public IP configuration")
	}
	if nic.Properties.NetworkSecurityGroup == nil {
		t.Fatal("expected NSG on NIC")
	}
}
