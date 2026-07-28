// (C) Copyright Confidential Containers Contributors
// SPDX-License-Identifier: Apache-2.0

package gcp

import "testing"

func TestValidateZoneScope(t *testing.T) {
	tests := []struct {
		name           string
		configuredZone string
		requestedZone  string
		wantRegion     string
		wantErr        bool
	}{
		{
			name:           "same region",
			configuredZone: "us-central1-a",
			requestedZone:  "us-central1-b",
			wantRegion:     "us-central1",
		},
		{
			name:           "different region",
			configuredZone: "us-central1-a",
			requestedZone:  "us-east1-b",
			wantErr:        true,
		},
		{
			name:           "invalid requested zone",
			configuredZone: "us-central1-a",
			requestedZone:  "invalid",
			wantErr:        true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := validateZoneScope(tt.configuredZone, tt.requestedZone)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateZoneScope() error = %v, wantErr %v", err, tt.wantErr)
			}
			if got != tt.wantRegion {
				t.Errorf("validateZoneScope() = %q, want %q", got, tt.wantRegion)
			}
		})
	}
}

func TestParseInstanceID(t *testing.T) {
	const (
		project = "operator-project"
		zone    = "us-central1-a"
	)

	tests := []struct {
		name     string
		id       string
		wantName string
		wantZone string
		wantErr  bool
	}{
		{
			name:     "simple name uses configured zone",
			id:       "podvm-example",
			wantName: "podvm-example",
			wantZone: zone,
		},
		{
			name:     "canonical ID in configured region",
			id:       "projects/operator-project/zones/us-central1-b/instances/podvm-example",
			wantName: "podvm-example",
			wantZone: "us-central1-b",
		},
		{
			name:    "reject different project",
			id:      "projects/other-project/zones/us-central1-b/instances/podvm-example",
			wantErr: true,
		},
		{
			name:    "reject different region",
			id:      "projects/operator-project/zones/us-east1-b/instances/podvm-example",
			wantErr: true,
		},
		{
			name:    "reject malformed ID",
			id:      "zones/us-central1-b/instances/podvm-example",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotName, gotZone, err := parseInstanceID(tt.id, project, zone)
			if (err != nil) != tt.wantErr {
				t.Fatalf("parseInstanceID() error = %v, wantErr %v", err, tt.wantErr)
			}
			if gotName != tt.wantName {
				t.Errorf("parseInstanceID() name = %q, want %q", gotName, tt.wantName)
			}
			if gotZone != tt.wantZone {
				t.Errorf("parseInstanceID() zone = %q, want %q", gotZone, tt.wantZone)
			}
		})
	}
}
