//go:build windows

package updater

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"syscall"
)

// Installer runs the install script from an extracted release directory.
type Installer interface {
	Run(extractedDir string) error
}

// RealInstaller runs the platform install script detached from the tray process group.
// When InstallerType is "msi", it launches the Burn bootstrapper .exe directly
// instead of running install.bat.
type RealInstaller struct{}

func NewRealInstaller() *RealInstaller { return &RealInstaller{} }

func (i *RealInstaller) Run(extractedDir string) error {
	if InstallerType == "msi" {
		return i.runBootstrapper(extractedDir)
	}
	return i.runBatchInstaller(extractedDir)
}

// runBatchInstaller runs install.bat from an extracted zip release.
func (i *RealInstaller) runBatchInstaller(extractedDir string) error {
	script := filepath.Join(extractedDir, "install.bat")
	cmd := exec.Command(script)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start install script: %w", err)
	}
	return nil
}

// runBootstrapper launches the Burn bootstrapper .exe from the extracted directory.
// The bootstrapper handles elevation (UAC prompt) and MSI upgrade internally.
func (i *RealInstaller) runBootstrapper(extractedDir string) error {
	matches, err := filepath.Glob(filepath.Join(extractedDir, "Scry2Setup-*.exe"))
	if err != nil || len(matches) == 0 {
		return fmt.Errorf("no Scry2Setup .exe found in %s", extractedDir)
	}
	cmd := exec.Command(matches[0])
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start bootstrapper: %w", err)
	}
	return nil
}
