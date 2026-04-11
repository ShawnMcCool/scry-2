package main

import (
	"net/http"
	"time"
)

// DashboardURL is the user-facing URL for the Scry2 dashboard in a prod install.
// The backend release binds this port in config/runtime.exs.
const DashboardURL = "http://localhost:6015"

// waitForBackendReady polls DashboardURL until the HTTP server responds or the
// timeout elapses. Returns true if the backend is reachable, false on timeout.
//
// Used on first-run auto-open so the browser doesn't race the backend coming up.
var waitForBackendReady = func(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 2 * time.Second}
	for time.Now().Before(deadline) {
		resp, err := client.Get(DashboardURL)
		if err == nil {
			resp.Body.Close()
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}
