package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

var fakeBackendBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "fakebackend-*")
	if err != nil {
		panic("failed to create temp dir: " + err.Error())
	}
	defer os.RemoveAll(dir)

	fakeBackendBin = filepath.Join(dir, "fakebackend")
	if runtime.GOOS == "windows" {
		fakeBackendBin += ".exe"
	}

	cmd := exec.Command("go", "build", "-o", fakeBackendBin, "./testutil/fakebackend")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		panic("failed to build fakebackend: " + err.Error())
	}

	os.Exit(m.Run())
}

func newTestBackend(t *testing.T) (*RealBackend, string) {
	t.Helper()
	pidFile := filepath.Join(t.TempDir(), "backend.pid")
	b := &RealBackend{
		binPath:          fakeBackendBin,
		extraEnv:         []string{"FAKE_BACKEND_PIDFILE=" + pidFile},
		WatchdogInterval: 100 * time.Millisecond,
		GracePeriod:      100 * time.Millisecond,
		RestartDelay:     100 * time.Millisecond,
	}
	return b, pidFile
}

func TestStart(t *testing.T) {
	b, _ := newTestBackend(t)

	b.Start()

	// Give the subprocess a moment to write the PID file.
	time.Sleep(200 * time.Millisecond)

	if !b.IsRunning() {
		t.Fatal("expected IsRunning() == true after Start()")
	}
}

func TestStop(t *testing.T) {
	b, _ := newTestBackend(t)

	b.Start()
	time.Sleep(200 * time.Millisecond)

	if !b.IsRunning() {
		t.Fatal("expected IsRunning() == true after Start()")
	}

	b.Stop()

	if b.IsRunning() {
		t.Fatal("expected IsRunning() == false after Stop()")
	}
}

func TestWatchdogNotifiesAfterConsecutiveFailures(t *testing.T) {
	notifyCh := make(chan struct{}, 1)

	b := &RealBackend{
		binPath:          "/nonexistent/fake-backend-bin",
		WatchdogInterval: 50 * time.Millisecond,
		GracePeriod:      50 * time.Millisecond,
		RestartDelay:     10 * time.Millisecond,
		FailureThreshold: 2,
		OnNotResponding: func() {
			select {
			case notifyCh <- struct{}{}:
			default:
			}
		},
	}

	quit := make(chan struct{})
	defer close(quit)
	b.StartWatchdog(quit)

	select {
	case <-notifyCh:
		// OnNotResponding was called — pass
	case <-time.After(2 * time.Second):
		t.Fatal("expected OnNotResponding to be called after consecutive failures")
	}
}

func TestWatchdogDoesNotNotifyWhileBackendHealthy(t *testing.T) {
	b, _ := newTestBackend(t)
	b.FailureThreshold = 2
	b.OnNotResponding = func() {
		t.Error("OnNotResponding should not be called when backend is healthy")
	}

	b.Start()
	time.Sleep(200 * time.Millisecond)

	quit := make(chan struct{})
	b.StartWatchdog(quit)

	time.Sleep(500 * time.Millisecond)
	close(quit)
}

func TestWatchdogRestarts(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "backend.pid")
	b := &RealBackend{
		binPath:          fakeBackendBin,
		extraEnv:         []string{"FAKE_BACKEND_PIDFILE=" + pidFile, "FAKE_BACKEND_CRASH_AFTER=1"},
		WatchdogInterval: 100 * time.Millisecond,
		GracePeriod:      100 * time.Millisecond,
		RestartDelay:     100 * time.Millisecond,
	}

	quit := make(chan struct{})
	defer close(quit)

	b.Start()
	b.StartWatchdog(quit)

	// Wait for crash + watchdog restart cycle (crash after 1s, watchdog polls every 100ms).
	time.Sleep(3 * time.Second)

	if !b.IsRunning() {
		t.Fatal("expected watchdog to have restarted the backend after crash")
	}
}

func TestWatchdogSkipsRestartDuringApply(t *testing.T) {
	tmp := t.TempDir()
	lockPath := filepath.Join(tmp, "apply.lock")
	pidFile := filepath.Join(tmp, "backend.pid")

	// Write an active lock before the watchdog spins up.
	payload := map[string]interface{}{
		"pid":        os.Getpid(),
		"version":    "0.15.0",
		"phase":      "downloading",
		"started_at": time.Now().UTC().Format(time.RFC3339),
	}
	raw, _ := json.Marshal(payload)
	if err := os.WriteFile(lockPath, raw, 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("SCRY2_APPLY_LOCK_PATH_OVERRIDE", lockPath)

	b := &RealBackend{
		binPath:          fakeBackendBin,
		extraEnv:         []string{"FAKE_BACKEND_PIDFILE=" + pidFile},
		WatchdogInterval: 50 * time.Millisecond,
		GracePeriod:      50 * time.Millisecond,
		RestartDelay:     50 * time.Millisecond,
	}

	// Do NOT call b.Start(); pid file absent → IsRunning() is false every tick.
	// If the watchdog calls Start(), the pid file will be written.
	quit := make(chan struct{})
	defer close(quit)
	b.StartWatchdog(quit)

	// Allow several watchdog ticks so, absent the lock, b.Start() would have
	// been called multiple times.
	time.Sleep(1 * time.Second)

	if _, err := os.Stat(pidFile); err == nil {
		t.Fatal("expected watchdog to skip Start() while apply lock is active, but pid file was created")
	}
}
