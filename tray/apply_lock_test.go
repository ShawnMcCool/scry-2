package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestApplyLockActive(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "apply.lock")

	if ApplyLockActive(lockPath) {
		t.Fatalf("expected false when file absent")
	}

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

	if !ApplyLockActive(lockPath) {
		t.Fatalf("expected true when fresh lock present")
	}

	// Stale lock (> 15 min)
	payload["started_at"] = time.Now().Add(-20 * time.Minute).UTC().Format(time.RFC3339)
	raw, _ = json.Marshal(payload)
	_ = os.WriteFile(lockPath, raw, 0o644)

	if ApplyLockActive(lockPath) {
		t.Fatalf("expected false when stale")
	}
}

func TestApplyLockMalformed(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "apply.lock")
	if err := os.WriteFile(lockPath, []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	if ApplyLockActive(lockPath) {
		t.Fatalf("malformed lock should be treated as inactive (allow restart)")
	}
}

func TestApplyLockPath(t *testing.T) {
	// Should be under DataDir() with basename apply.lock
	p := ApplyLockPath()
	if filepath.Base(p) != "apply.lock" {
		t.Fatalf("expected basename apply.lock, got %s", filepath.Base(p))
	}
	if filepath.Dir(p) != DataDir() {
		t.Fatalf("expected lock under DataDir(); got dir=%s want=%s", filepath.Dir(p), DataDir())
	}
}

func TestApplyLockPathOverride(t *testing.T) {
	t.Setenv("SCRY2_APPLY_LOCK_PATH_OVERRIDE", "/tmp/custom/apply.lock")
	if got := ApplyLockPath(); got != "/tmp/custom/apply.lock" {
		t.Fatalf("override not honored; got %s", got)
	}
}
