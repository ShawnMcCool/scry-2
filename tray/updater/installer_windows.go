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
// When InstallerType is "msi", it invokes msiexec.exe /i against the downloaded MSI.
type RealInstaller struct{}

func NewRealInstaller() *RealInstaller { return &RealInstaller{} }

func (i *RealInstaller) Run(extractedDir string) error {
	if InstallerType == "msi" {
		return i.runMsiInstaller(extractedDir)
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

// runMsiInstaller invokes msiexec.exe to silently install the downloaded MSI.
// msiexec handles UAC elevation internally; the process is detached so the
// tray can exit without interrupting the install.
func (i *RealInstaller) runMsiInstaller(extractedDir string) error {
	matches, err := filepath.Glob(filepath.Join(extractedDir, "*.msi"))
	if err != nil || len(matches) == 0 {
		return fmt.Errorf("no .msi found in %s", extractedDir)
	}
	cmd := exec.Command("msiexec.exe", "/i", matches[0], "/qn", "/norestart")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start msiexec: %w", err)
	}
	return nil
}
