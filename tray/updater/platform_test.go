package updater_test

import (
	"testing"

	"scry2/tray/updater"
)

func TestArchiveName(t *testing.T) {
	tests := []struct {
		goos          string
		goarch        string
		version       string
		installerType string
		want          string
		wantErr       bool
	}{
		{"linux", "amd64", "v0.3.0", "zip", "scry_2-v0.3.0-linux-x86_64.tar.gz", false},
		{"darwin", "arm64", "v0.3.0", "zip", "scry_2-v0.3.0-macos-aarch64.tar.gz", false},
		{"darwin", "amd64", "v0.3.0", "zip", "scry_2-v0.3.0-macos-x86_64.tar.gz", false},
		{"windows", "amd64", "v0.3.0", "zip", "scry_2-v0.3.0-windows-x86_64.zip", false},
		{"windows", "amd64", "v0.3.0", "msi", "Scry2Setup-v0.3.0.exe", false},
		{"linux", "amd64", "v0.3.0", "msi", "scry_2-v0.3.0-linux-x86_64.tar.gz", false},
		{"freebsd", "amd64", "v0.3.0", "zip", "", true},
	}
	for _, tc := range tests {
		got, err := updater.ArchiveName(tc.goos, tc.goarch, tc.version, tc.installerType)
		if (err != nil) != tc.wantErr {
			t.Errorf("ArchiveName(%q,%q,%q,%q) err=%v, wantErr=%v", tc.goos, tc.goarch, tc.version, tc.installerType, err, tc.wantErr)
			continue
		}
		if got != tc.want {
			t.Errorf("ArchiveName(%q,%q,%q,%q) = %q, want %q", tc.goos, tc.goarch, tc.version, tc.installerType, got, tc.want)
		}
	}
}

func TestCurrentArchiveName(t *testing.T) {
	name, err := updater.CurrentArchiveName("v0.3.0")
	if err != nil {
		t.Skipf("platform not supported: %v", err)
	}
	if name == "" {
		t.Error("expected non-empty archive name")
	}
}
