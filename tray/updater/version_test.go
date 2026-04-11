package updater_test

import (
	"testing"

	"scry2/tray/updater"
)

func TestIsNewer(t *testing.T) {
	tests := []struct {
		latest  string
		current string
		want    bool
	}{
		{"v0.3.0", "v0.2.0", true},
		{"v0.2.1", "v0.2.0", true},
		{"v1.0.0", "v0.9.9", true},
		{"v0.2.0", "v0.2.0", false},
		{"v0.1.0", "v0.2.0", false},
		{"v0.2.0", "v0.2.1", false},
		{"bad-tag", "v0.2.0", false},
		{"v0.2.0", "bad-tag", false},
		{"", "v0.2.0", false},
		{"v0.2.0", "", false},
	}
	for _, tc := range tests {
		got := updater.IsNewer(tc.latest, tc.current)
		if got != tc.want {
			t.Errorf("IsNewer(%q, %q) = %v, want %v", tc.latest, tc.current, got, tc.want)
		}
	}
}
