package updater

import (
	"fmt"
	"runtime"
)

// ArchiveName returns the release archive filename for the given platform and version.
// goos and goarch should be runtime.GOOS and runtime.GOARCH values.
func ArchiveName(goos, goarch, version string) (string, error) {
	suffix, err := archiveSuffix(goos, goarch)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("scry_2-%s-%s", version, suffix), nil
}

// CurrentArchiveName returns the archive name for the current runtime platform.
func CurrentArchiveName(version string) (string, error) {
	return ArchiveName(runtime.GOOS, runtime.GOARCH, version)
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
