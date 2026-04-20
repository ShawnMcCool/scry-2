package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

const applyLockMaxAge = 15 * time.Minute

// ApplyLockPath returns the on-disk coordination file path the Elixir
// self-updater writes during an apply. The tray's watchdog consults this
// path to decide whether to restart the backend on failure — during an
// apply it MUST NOT, because the installer is deliberately tearing the
// backend down.
//
// The SCRY2_APPLY_LOCK_PATH_OVERRIDE env var allows tests (and manual
// debugging) to redirect the lock to a specific path.
func ApplyLockPath() string {
	if override := os.Getenv("SCRY2_APPLY_LOCK_PATH_OVERRIDE"); override != "" {
		return override
	}
	return filepath.Join(DataDir(), "apply.lock")
}

type applyLockContents struct {
	Pid       int    `json:"pid"`
	Version   string `json:"version"`
	Phase     string `json:"phase"`
	StartedAt string `json:"started_at"`
}

// ApplyLockActive returns true if the lock exists, is parseable JSON,
// and is fresher than applyLockMaxAge. Malformed or stale locks are
// treated as inactive — the watchdog should restart normally.
func ApplyLockActive(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}

	var contents applyLockContents
	if err := json.Unmarshal(data, &contents); err != nil {
		return false
	}

	started, err := time.Parse(time.RFC3339, contents.StartedAt)
	if err != nil {
		return false
	}

	return time.Since(started) < applyLockMaxAge
}
