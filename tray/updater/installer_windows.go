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
type RealInstaller struct{}

func NewRealInstaller() *RealInstaller { return &RealInstaller{} }

func (i *RealInstaller) Run(extractedDir string) error {
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
