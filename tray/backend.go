package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// BackendRunner manages the Scry2 backend subprocess lifecycle.
type BackendRunner interface {
	Start()
	Stop()
	IsRunning() bool
	StartWatchdog(quitCh <-chan struct{})
}

// RealBackend manages the backend subprocess via the scry_2 release binary.
type RealBackend struct {
	binPath          string
	extraEnv         []string      // appended to os.Environ() for each subprocess; used in tests
	WatchdogInterval time.Duration // how often to poll (default 10s)
	GracePeriod      time.Duration // initial startup grace + post-restart grace (default 20s)
	RestartDelay     time.Duration // delay before restarting after crash (default 2s)
	FailureThreshold int           // consecutive failures before calling OnNotResponding (default 3)
	OnNotResponding  func()        // called once when FailureThreshold consecutive failures occur
	OnRecovered      func()        // called when backend becomes healthy after OnNotResponding fired
}

func newRealBackend() *RealBackend {
	return &RealBackend{
		binPath:          resolveBackendBin(),
		WatchdogInterval: 10 * time.Second,
		GracePeriod:      20 * time.Second,
		RestartDelay:     2 * time.Second,
		FailureThreshold: 3,
	}
}

func resolveBackendBin() string {
	exe, err := os.Executable()
	if err != nil || exe == "" {
		fmt.Fprintf(os.Stderr, "scry2-tray: cannot resolve own path: %v\n", err)
		os.Exit(1)
	}
	dir := filepath.Dir(exe)
	bin := filepath.Join(dir, "bin", "scry_2")
	if runtime.GOOS == "windows" {
		return bin + ".bat"
	}
	return bin
}

func (b *RealBackend) cmd(args ...string) *exec.Cmd {
	c := exec.Command(b.binPath, args...)
	if len(b.extraEnv) > 0 {
		c.Env = append(os.Environ(), b.extraEnv...)
	}
	setCmdAttrs(c)
	return c
}

func (b *RealBackend) Start() {
	b.cmd("start").Start() //nolint:errcheck
}

func (b *RealBackend) Stop() {
	b.cmd("stop").Run() //nolint:errcheck
}

func (b *RealBackend) IsRunning() bool {
	return b.cmd("pid").Run() == nil
}

func (b *RealBackend) StartWatchdog(quitCh <-chan struct{}) {
	go b.watchdog(quitCh)
}

func (b *RealBackend) watchdog(quitCh <-chan struct{}) {
	select {
	case <-time.After(b.GracePeriod):
	case <-quitCh:
		return
	}

	threshold := b.FailureThreshold
	if threshold <= 0 {
		threshold = 3
	}

	consecutiveFailures := 0
	notified := false

	for {
		select {
		case <-time.After(b.WatchdogInterval):
		case <-quitCh:
			return
		}

		if !b.IsRunning() {
			consecutiveFailures++

			if consecutiveFailures >= threshold && !notified {
				notified = true
				if b.OnNotResponding != nil {
					b.OnNotResponding()
				}
			}

			select {
			case <-time.After(b.RestartDelay):
			case <-quitCh:
				return
			}

			if ApplyLockActive(ApplyLockPath()) {
				// An apply is in progress; the installer will stop and relaunch
				// the tray. Skip restart — we'd only fight the installer.
				continue
			}

			b.Start()
			select {
			case <-time.After(b.GracePeriod):
			case <-quitCh:
				return
			}
		} else {
			if notified && b.OnRecovered != nil {
				b.OnRecovered()
			}
			consecutiveFailures = 0
			notified = false
		}
	}
}
