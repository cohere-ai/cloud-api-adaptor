// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package podnetwork

import "testing"

func TestResolveMTU(t *testing.T) {
	tests := []struct {
		name        string
		discovered  int
		configured  int
		want        int
	}{
		{name: "unset uses discovered", discovered: 1500, configured: 0, want: 1500},
		{name: "negative configured ignored", discovered: 1500, configured: -1, want: 1500},
		{name: "cap below discovered", discovered: 1500, configured: 1200, want: 1200},
		{name: "does not raise above discovered", discovered: 1200, configured: 1500, want: 1200},
		{name: "equal keeps value", discovered: 1200, configured: 1200, want: 1200},
		{name: "configured when discovered missing", discovered: 0, configured: 1200, want: 1200},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := resolveMTU(tt.discovered, tt.configured); got != tt.want {
				t.Fatalf("resolveMTU(%d, %d) = %d, want %d", tt.discovered, tt.configured, got, tt.want)
			}
		})
	}
}
