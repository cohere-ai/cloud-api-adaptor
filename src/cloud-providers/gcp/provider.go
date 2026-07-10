// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package gcp

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net/netip"
	"strings"

	"cloud.google.com/go/auth/credentials"
	compute "cloud.google.com/go/compute/apiv1"
	computepb "cloud.google.com/go/compute/apiv1/computepb"
	crm "cloud.google.com/go/resourcemanager/apiv3"
	resourcemanagerpb "cloud.google.com/go/resourcemanager/apiv3/resourcemanagerpb"
	provider "github.com/confidential-containers/cloud-api-adaptor/src/cloud-providers"
	"github.com/confidential-containers/cloud-api-adaptor/src/cloud-providers/util"
	"github.com/confidential-containers/cloud-api-adaptor/src/cloud-providers/util/cloudinit"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
	proto "google.golang.org/protobuf/proto"
)

var logger = log.New(log.Writer(), "[adaptor/cloud/gcp] ", log.LstdFlags|log.Lmsgprefix)
var computeScope = "https://www.googleapis.com/auth/compute"

const maxInstanceNameLen = 63

type gcpProvider struct {
	serviceConfig   *Config
	instancesClient *compute.InstancesClient
}

func (p *gcpProvider) ConfigVerifier() error {
	return nil
}

func NewProvider(config *Config) (provider.Provider, error) {
	logger.Printf("gcp config: %#v", config.Redact())
	provider := &gcpProvider{
		serviceConfig:   config,
		instancesClient: nil,
	}
	if config.GcpCredentials != "" {
		creds, err := credentials.NewCredentialsFromJSON(credentials.ServiceAccount, []byte(config.GcpCredentials), &credentials.DetectOptions{
			Scopes: []string{computeScope},
		})
		if err != nil {
			return nil, fmt.Errorf("configuration error when using creds: %s", err)
		}
		provider.instancesClient, err = compute.NewInstancesRESTClient(context.TODO(), option.WithAuthCredentials(creds))
		if err != nil {
			return nil, fmt.Errorf("NewInstancesRESTClient with credentials error: %s", err)
		}
	} else {
		var err error
		provider.instancesClient, err = compute.NewInstancesRESTClient(context.TODO())
		if err != nil {
			return nil, fmt.Errorf("NewInstancesRESTClient error: %s", err)
		}
	}
	return provider, nil
}

func parseIPString(ipStr string) (netip.Addr, error) {
	ip, err := netip.ParseAddr(ipStr)
	if err != nil {
		return netip.Addr{}, fmt.Errorf("failed to parse pod node IP %q: %w", ipStr, err)
	}

	return ip, nil
}

func getNatIPs(nic *computepb.NetworkInterface) ([]netip.Addr, error) {
	var natIPs []netip.Addr

	for _, access := range nic.GetAccessConfigs() {
		ip, err := parseIPString(access.GetNatIP())
		if err != nil {
			return nil, err
		}

		natIPs = append(natIPs, ip)
	}

	return natIPs, nil
}

func getIPs(intfcs []*computepb.NetworkInterface, usePublicIPs bool) ([]netip.Addr, error) {
	var podNodeIPs []netip.Addr

	for _, nic := range intfcs {
		var ips []netip.Addr

		if usePublicIPs {
			var err error

			ips, err = getNatIPs(nic)
			if err != nil {
				return nil, err
			}
		} else {
			ip, err := parseIPString(nic.GetNetworkIP())
			if err != nil {
				return nil, err
			}

			ips = []netip.Addr{ip}
		}

		podNodeIPs = append(podNodeIPs, ips...)
	}

	return podNodeIPs, nil
}

func (p *gcpProvider) ListAllTags(ctx context.Context, projectID string) (map[string]map[string]*resourcemanagerpb.TagValue, error) {
	tagKeysClient, err := crm.NewTagKeysClient(ctx)
	if err != nil {
		return nil, err
	}
	defer tagKeysClient.Close()

	tagValuesClient, err := crm.NewTagValuesClient(ctx)
	if err != nil {
		return nil, err
	}
	defer tagValuesClient.Close()

	parent := fmt.Sprintf("projects/%s", projectID)
	tags := make(map[string]map[string]*resourcemanagerpb.TagValue)

	it := tagKeysClient.ListTagKeys(ctx, &resourcemanagerpb.ListTagKeysRequest{Parent: parent})
	for {
		key, err := it.Next()
		if err != nil {
			break
		}
		tagKeyID := key.Name
		keyName := key.ShortName
		tags[keyName] = make(map[string]*resourcemanagerpb.TagValue)

		valIt := tagValuesClient.ListTagValues(ctx, &resourcemanagerpb.ListTagValuesRequest{Parent: tagKeyID})
		for {
			val, err := valIt.Next()
			if err != nil {
				break
			}
			tags[keyName][val.ShortName] = val
		}
	}
	return tags, nil
}

func (p *gcpProvider) getImageSizeGB(ctx context.Context, image string) (int64, error) {
	client, err := compute.NewImagesRESTClient(ctx)
	if err != nil {
		return 0, fmt.Errorf("failed to create compute client: %w", err)
	}
	defer client.Close()

	var projectID string
	var imageName string

	// Parse project ID from full path if present
	// Supported formats:
	// - /projects/PROJECT-ID/global/images/IMAGE-NAME
	// - projects/PROJECT-ID/global/images/IMAGE-NAME
	// - https://www.googleapis.com/compute/v1/projects/PROJECT-ID/global/images/IMAGE-NAME
	if strings.HasPrefix(image, "/projects/") || strings.HasPrefix(image, "projects/") || strings.HasPrefix(image, "https://") {
		parts := strings.Split(image, "/")
		// Look for pattern: .../images/IMAGE-NAME
		for i := len(parts) - 2; i >= 0; i-- {
			if parts[i] == "images" && i >= 2 {
				projectID = parts[i-2]
				imageName = parts[len(parts)-1]
				break
			}
		}
	}

	// Fallback to ConfigMap project and image name
	if projectID == "" {
		projectID = p.serviceConfig.ProjectID
		parts := strings.Split(image, "/")
		imageName = parts[len(parts)-1]
	}

	req := &computepb.GetImageRequest{
		Project: projectID,
		Image:   imageName,
	}

	img, err := client.Get(ctx, req)
	if err != nil {
		return 0, fmt.Errorf("Failed to get image for %s: %w", image, err)
	}

	return img.GetDiskSizeGb(), nil
}

func chooseString(annotationValue, defaultValue string) string {
	if annotationValue != "" {
		return annotationValue
	}
	return defaultValue
}

func chooseBool(annotationValue *bool, defaultValue bool) bool {
	if annotationValue != nil {
		return *annotationValue
	}
	return defaultValue
}

func chooseInt64(annotationValue int64, defaultValue int) int64 {
	if annotationValue > 0 {
		return annotationValue
	}
	return int64(defaultValue)
}

func chooseNetworkTags(annotationValue []string, defaultValue networkTags) []string {
	if len(annotationValue) > 0 {
		return annotationValue
	}
	items := make([]string, len(defaultValue))
	copy(items, defaultValue)
	return items
}

func chooseTags(annotationValue map[string]string, defaultValue provider.KeyValueFlag) map[string]string {
	if len(annotationValue) > 0 {
		return annotationValue
	}
	tags := make(map[string]string, len(defaultValue))
	for key, value := range defaultValue {
		tags[key] = value
	}
	return tags
}

// Select a machine type based on the memory, vcpu, and GPU requirements
func (p *gcpProvider) selectMachineType(ctx context.Context, spec provider.InstanceTypeSpec) (string, error) {
	machineTypes := []string(p.serviceConfig.MachineTypes)
	if len(spec.InstanceTypes) > 0 {
		machineTypes = spec.InstanceTypes
	}
	return provider.SelectInstanceTypeToUse(spec, p.serviceConfig.MachineTypeSpecList, machineTypes, p.serviceConfig.MachineType)
}

func (p *gcpProvider) CreateInstance(ctx context.Context, podName, sandboxID string, cloudConfig cloudinit.CloudConfigGenerator, spec provider.InstanceTypeSpec) (instance *provider.Instance, err error) {

	instanceName := util.GenerateInstanceName(podName, sandboxID, maxInstanceNameLen)
	logger.Printf("CreateInstance: name: %q", instanceName)

	projectID := chooseString(spec.ProjectID, p.serviceConfig.ProjectID)
	zone := chooseString(spec.Zone, p.serviceConfig.Zone)
	network := chooseString(spec.Network, p.serviceConfig.Network)
	subnetwork := chooseString(spec.Subnetwork, p.serviceConfig.Subnetwork)
	diskType := chooseString(spec.DiskType, p.serviceConfig.DiskType)
	disableCVM := chooseBool(spec.DisableCVM, p.serviceConfig.DisableCVM)
	confidentialType := chooseString(spec.ConfidentialType, p.serviceConfig.ConfidentialType)
	rootVolumeSize := chooseInt64(spec.RootVolumeSize, p.serviceConfig.RootVolumeSize)
	usePublicIP := chooseBool(spec.UsePublicIP, p.serviceConfig.UsePublicIP)
	useSpot := p.serviceConfig.UseSpotInstances
	if spec.UseSpotSet {
		useSpot = spec.UseSpot
	}
	networkTags := chooseNetworkTags(spec.NetworkTags, p.serviceConfig.NetworkTags)
	tags := chooseTags(spec.Tags, p.serviceConfig.Tags)

	userData, err := cloudConfig.Generate()
	if err != nil {
		return nil, err
	}

	// Check if the tags exist within the project
	// Otherwise, abort the instance creation
	allTagValues := make([]*resourcemanagerpb.TagValue, 0)
	if len(tags) > 0 {
		allTags, err := p.ListAllTags(ctx, projectID)
		if err != nil {
			return nil, fmt.Errorf("Aborting: Failed to list tags: %w", err)
		}

		for tagKey, tagValue := range tags {
			tagID := allTags[tagKey][tagValue]
			if tagID == nil {
				msg := fmt.Sprintf("Aborting: Tag %s=%s not found", tagKey, tagValue)
				logger.Print(msg)
				return nil, fmt.Errorf("%s", msg)
			}
			allTagValues = append(allTagValues, tagID)
		}
	}

	//Convert userData to base64
	userDataEnc := base64.StdEncoding.EncodeToString([]byte(userData))

	// It's expected that the image from the annotation will follow one of supported formats:
	// - "projects/<project>/global/images/<imageid>" and "/projects/<project>/global/images/<imageid>",
	// - url: "https://www.googleapis.com/compute/v1/projects/<project>/global/images/<imageid>",
	// - simple "<imageid>" if the image is present on the same project.
	var srcImage *string
	if hasAnyPrefix(p.serviceConfig.ImageName, "projects/", "/projects", "https") {
		srcImage = proto.String(p.serviceConfig.ImageName)
	} else {
		srcImage = proto.String(fmt.Sprintf("projects/%s/global/images/%s", projectID, p.serviceConfig.ImageName))
	}

	if spec.Image != "" {
		logger.Printf("Choosing %s from annotation as the GCP image for the PodVM image", spec.Image)
		if hasAnyPrefix(spec.Image, "projects/", "/projects", "https") {
			srcImage = proto.String(spec.Image)
		} else {
			srcImage = proto.String(fmt.Sprintf("projects/%s/global/images/%s", projectID, spec.Image))
		}
	}

	// Select and validate machine type
	machineType, err := p.selectMachineType(ctx, spec)
	if err != nil {
		return nil, fmt.Errorf("failed to select machine type: %w", err)
	}

	imageSizeGB, err := p.getImageSizeGB(ctx, *srcImage)
	if err != nil {
		return nil, fmt.Errorf("Failed to get image size: %w", err)
	}

	// If user provided RootVolumeSize, use the larger of the two
	if rootVolumeSize > 0 && rootVolumeSize > imageSizeGB {
		imageSizeGB = rootVolumeSize
	}

	// Format subnetwork: support both short names and full paths
	// GCP accepts formats:
	// - "projects/<project>/regions/<region>/subnetworks/<subnetwork>" (full path)
	// - "regions/<region>/subnetworks/<subnetwork>" (partial path)
	// - "<subnetwork>" (short name, will be formatted as full path)
	// Extract region from zone (e.g., "us-central1-a" -> "us-central1")
	var subnetworkValue *string
	if subnetwork != "" {
		subnetworkName := subnetwork
		if hasAnyPrefix(subnetworkName, "projects/", "/projects", "regions/", "https") {
			subnetworkValue = proto.String(subnetworkName)
		} else {
			// Extract region from zone (format: "region-zone" e.g., "us-central1-a")
			zoneParts := strings.Split(zone, "-")
			if len(zoneParts) >= 2 {
				region := strings.Join(zoneParts[:len(zoneParts)-1], "-")
				formattedSubnetwork := fmt.Sprintf("projects/%s/regions/%s/subnetworks/%s", projectID, region, subnetworkName)
				subnetworkValue = proto.String(formattedSubnetwork)
			} else {
				// Fallback: assume zone format is invalid, try to use as-is
				subnetworkValue = proto.String(subnetworkName)
			}
		}
	}

	networkInterface := &computepb.NetworkInterface{
		Network:   proto.String(network),
		StackType: proto.String("IPV4_Only"),
	}
	// Only attach an ephemeral public IP (1:1 External NAT) when the operator
	// explicitly opts in via USE_PUBLIC_IP. With the default (false), peer pod
	// VMs are private-only and egress via Cloud NAT, matching the behavior of
	// the Azure and AWS providers.
	if usePublicIP {
		networkInterface.AccessConfigs = []*computepb.AccessConfig{
			{
				Name:        proto.String("External NAT"),
				NetworkTier: proto.String("STANDARD"),
			},
		}
	}
	if subnetworkValue != nil {
		networkInterface.Subnetwork = subnetworkValue
	}

	instanceResource := &computepb.Instance{
		Name: proto.String(instanceName),
		Disks: []*computepb.AttachedDisk{
			{
				InitializeParams: &computepb.AttachedDiskInitializeParams{
					DiskSizeGb:  proto.Int64(imageSizeGB),
					SourceImage: srcImage,
					DiskType:    proto.String(fmt.Sprintf("zones/%s/diskTypes/%s", zone, diskType)),
				},
				AutoDelete: proto.Bool(true),
				Boot:       proto.Bool(true),
				Type:       proto.String(computepb.AttachedDisk_PERSISTENT.String()),
			},
		},
		Metadata: &computepb.Metadata{
			Items: []*computepb.Items{
				{
					Key:   proto.String("user-data"),
					Value: proto.String(userDataEnc),
				},
				{
					Key:   proto.String("user-data-encoding"),
					Value: proto.String("base64"),
				},
			},
		},
		MachineType:       proto.String(fmt.Sprintf("zones/%s/machineTypes/%s", zone, machineType)),
		NetworkInterfaces: []*computepb.NetworkInterface{networkInterface},
	}

	if len(networkTags) > 0 {
		instanceResource.Tags = &computepb.Tags{Items: networkTags}
	}

	// Check if OnHostMaintenance needs to be set to TERMINATE
	// This is required for:
	// 1. Confidential VMs
	// 2. GPU instances (when spec.GPUs > 0)
	requiresTerminatePolicy := false

	if !disableCVM {
		if confidentialType == "" {
			return nil, fmt.Errorf("ConfidentialType must be set when using Confidential VM.")
		}

		instanceResource.ConfidentialInstanceConfig = &computepb.ConfidentialInstanceConfig{
			ConfidentialInstanceType:  proto.String(confidentialType),
			EnableConfidentialCompute: proto.Bool(true),
		}
		requiresTerminatePolicy = true
	}

	// Check if GPUs are requested via annotation
	if spec.GPUs > 0 {
		logger.Printf("GPUs requested (%d), setting OnHostMaintenance to TERMINATE", spec.GPUs)
		requiresTerminatePolicy = true
	}

	if requiresTerminatePolicy || useSpot {
		provisioningModel := "STANDARD"
		if useSpot {
			provisioningModel = "SPOT"
			logger.Printf("Spot instance requested, setting ProvisioningModel to SPOT")
		}
		instanceResource.Scheduling = &computepb.Scheduling{
			OnHostMaintenance: proto.String("TERMINATE"),
			ProvisioningModel: proto.String(provisioningModel),
		}
	}

	insertReq := &computepb.InsertInstanceRequest{
		Project:          projectID,
		Zone:             zone,
		InstanceResource: instanceResource,
	}

	op, err := p.instancesClient.Insert(ctx, insertReq)
	if err != nil {
		return nil, fmt.Errorf("Instances.Insert error: %s. req: %v", err, insertReq)
	}
	err = op.Wait(ctx)
	if err != nil {
		return nil, fmt.Errorf("waiting for Instances.Insert error: %s. req: %v", err, insertReq)
	}
	logger.Printf("created an instance %s for sandbox %s", instanceName, sandboxID)

	// Create partial instance to return on error (allows caller to cleanup)
	instance = &provider.Instance{
		ID:   instanceName,
		Name: instanceName,
	}
	if projectID != p.serviceConfig.ProjectID || zone != p.serviceConfig.Zone {
		instance.ID = fmt.Sprintf("projects/%s/zones/%s/instances/%s", projectID, zone, instanceName)
	}

	getReq := &computepb.GetInstanceRequest{
		Project:  projectID,
		Zone:     zone,
		Instance: instanceName,
	}

	gcpInstance, err := p.instancesClient.Get(ctx, getReq)
	if err != nil {
		return instance, fmt.Errorf("unable to get instance: %w, req: %v", err, getReq)
	}
	logger.Printf("instance name %s, id %d", gcpInstance.GetName(), gcpInstance.GetId())

	// Binding all the tagValues to the instance that was already created
	// Specific endpoint is needed for tag bindings because global endpoint
	// doesn't work for zonal resources.
	tagBindingsClient, err := crm.NewTagBindingsClient(ctx,
		option.WithEndpoint(fmt.Sprintf("%s-cloudresourcemanager.googleapis.com:443", zone)),
	)
	if err != nil {
		return instance, fmt.Errorf("failed to create bind client: %w", err)
	}
	defer tagBindingsClient.Close()

	parent := fmt.Sprintf("//compute.googleapis.com/projects/%s/zones/%s/instances/%d", projectID, zone, gcpInstance.GetId())

	for _, tagValue := range allTagValues {
		logger.Printf("Creating tag binding for %s on %s", tagValue.Name, parent)

		tagBinding := &resourcemanagerpb.TagBinding{
			Parent:   parent,
			TagValue: tagValue.Name,
		}

		req := &resourcemanagerpb.CreateTagBindingRequest{
			TagBinding: tagBinding,
		}

		op, err := tagBindingsClient.CreateTagBinding(ctx, req)
		if err != nil {
			return instance, fmt.Errorf("API call to create tag binding failed for %s: %v", tagValue, err)
		}

		_, err = op.Wait(ctx)
		if err != nil {
			return instance, fmt.Errorf("Long-running operation for tag binding %s failed: %v", tagValue, err)
		}

		logger.Printf("Created tag binding for %s on %s successfully", tagValue, parent)
	}

	ips, err := getIPs(gcpInstance.GetNetworkInterfaces(), usePublicIP)
	if err != nil {
		logger.Printf("failed to get IPs for the instance: %v", err)
		return instance, err
	}

	logger.Printf("Found pod node IP(s): %v", ips)

	instance.IPs = ips

	return instance, nil
}

func (p *gcpProvider) DeleteInstance(ctx context.Context, instanceID string) error {
	projectID := p.serviceConfig.ProjectID
	zone := p.serviceConfig.Zone
	instanceName := instanceID

	parts := strings.Split(instanceID, "/")
	for i := 0; i < len(parts)-1; i++ {
		switch parts[i] {
		case "projects":
			projectID = parts[i+1]
		case "zones":
			zone = parts[i+1]
		case "instances":
			instanceName = parts[i+1]
		}
	}

	req := &computepb.DeleteInstanceRequest{
		Project:  projectID,
		Zone:     zone,
		Instance: instanceName,
	}
	op, err := p.instancesClient.Delete(ctx, req)
	if err != nil {
		if isGCPNotFound(err) {
			logger.Printf("instance %s already deleted, nothing to do", instanceID)
			return nil
		}
		return fmt.Errorf("Instances.Delete error: %w, req: %v", err, req)
	}
	err = op.Wait(ctx)
	if err != nil {
		return fmt.Errorf("waiting for Instances.Delete error: %s. req: %v", err, req)
	}
	logger.Printf("deleted an instance %s", instanceID)
	return nil
}

func isGCPNotFound(err error) bool {
	var apiErr *googleapi.Error
	if errors.As(err, &apiErr) {
		return apiErr.Code == 404
	}
	return false
}

func (p *gcpProvider) Teardown() error {
	return nil
}

func hasAnyPrefix(s string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}
