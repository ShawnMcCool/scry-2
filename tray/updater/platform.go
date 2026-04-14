package updater

import (
	"fmt"
	"runtime"
	"strings"
)

// ArchiveName returns the release asset filename for the given platform and version.
// When installerType is "msi" and the platform is Windows, it returns the raw MSI
// filename (strips the leading "v" from the version tag to match build output).
func ArchiveName(goos, goarch, version, installerType string) (string, error) {
	if installerType == "msi" && goos == "windows" {
		return fmt.Sprintf("Scry2-%s.msi", strings.TrimPrefix(version, "v")), nil
	}
	suffix, err := archiveSuffix(goos, goarch)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("scry_2-%s-%s", version, suffix), nil
}

// CurrentArchiveName returns the asset name for the current runtime platform,
// using the build-time InstallerType to select zip vs MSI format.
func CurrentArchiveName(version string) (string, error) {
	return ArchiveName(runtime.GOOS, runtime.GOARCH, version, InstallerType)
}

func archiveSuffix(goos, goarch string) (string, error) {
	switch goos + "/" + goarch {
	case "linux/amd64":
		return "linux-x86_64.tar.gz", nil
	case "darwin/arm64":
		return "macos-aarch64.tar.gz", nil
	case "darwin/amd64":
		return "macos-x86_64.tar.gz", nil
	case "windows/amd64":
		return "windows-x86_64.zip", nil
	default:
		return "", fmt.Errorf("unsupported platform: %s/%s", goos, goarch)
	}
}
