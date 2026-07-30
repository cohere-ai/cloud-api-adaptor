// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package podnetwork

import "testing"

func TestResolveMTU(t *testing.T) {
	tests := []struct {
		name         string
		discovered   int
		configured   int
		want         int
		wantOverride bool
	}{
		{name: "unset uses discovered", discovered: 1500, configured: 0, want: 1500},
		{name: "cap below discovered", discovered: 1500, configured: 1200, want: 1200, wantOverride: true},
		{name: "does not raise above discovered", discovered: 1200, configured: 1500, want: 1200},
		{name: "equal keeps value", discovered: 1200, configured: 1200, want: 1200},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, override := resolveMTU(tt.discovered, tt.configured)
			if got != tt.want || override != tt.wantOverride {
				t.Fatalf("resolveMTU(%d, %d) = (%d, %t), want (%d, %t)",
					tt.discovered, tt.configured, got, override, tt.want, tt.wantOverride)
			}
		})
	}
}

func TestValidateMTU(t *testing.T) {
	tests := []struct {
		name    string
		mtu     int
		wantErr bool
	}{
		{name: "unset", mtu: 0},
		{name: "IPv4 minimum", mtu: 68},
		{name: "below IPv4 minimum", mtu: 67, wantErr: true},
		{name: "negative", mtu: -1, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateMTU(tt.mtu); (err != nil) != tt.wantErr {
				t.Fatalf("validateMTU(%d) error = %v, wantErr %v", tt.mtu, err, tt.wantErr)
			}
		})
	}
}
