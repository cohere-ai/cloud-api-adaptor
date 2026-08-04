// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package tunneler

import "strings"

// MinIPv4MTU is the minimum legal IPv4 interface MTU.
const MinIPv4MTU = 68

type TunnelerConfigurator interface {
	Tunneler
	Configure(*NetworkConfig, *Config) error
}

type NetworkConfig struct {
	TunnelType          string
	HostInterface       string
	VXLAN               VXLANConfig
	ExternalNetViaPodVM bool
	PodSubnetCIDRs      SubnetCIDRs
	// MTU, when > 0, caps the overlay MTU advertised to the peer pod.
	// Account for tunnel overhead when deriving it from an underlay path MTU.
	MTU int
}

type VXLANConfig struct {
	Port  int
	MinID int
}

type SubnetCIDRs []string

func (i *SubnetCIDRs) String() string {
	return strings.Join(*i, ", ")
}

func (i *SubnetCIDRs) Set(value string) error {
	parts := strings.Split(value, ",")

	for _, part := range parts {
		*i = append(*i, strings.TrimSpace(part))
	}
	return nil
}
