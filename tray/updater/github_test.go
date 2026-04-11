package updater_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"scry2/tray/updater"
)

func TestGitHubChecker_LatestRelease_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"tag_name": "v0.3.0",
			"assets": []map[string]any{
				{"name": "scry_2-v0.3.0-linux-x86_64.tar.gz", "browser_download_url": "https://example.com/scry_2-v0.3.0-linux-x86_64.tar.gz"},
				{"name": "scry_2-v0.3.0-macos-aarch64.tar.gz", "browser_download_url": "https://example.com/scry_2-v0.3.0-macos-aarch64.tar.gz"},
			},
		})
	}))
	defer srv.Close()

	checker := updater.NewGitHubChecker(srv.URL)
	release, err := checker.LatestRelease("scry_2-v0.3.0-linux-x86_64.tar.gz")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if release.Version != "v0.3.0" {
		t.Errorf("Version = %q, want %q", release.Version, "v0.3.0")
	}
	if release.ArchiveURL != "https://example.com/scry_2-v0.3.0-linux-x86_64.tar.gz" {
		t.Errorf("ArchiveURL = %q", release.ArchiveURL)
	}
}

func TestGitHubChecker_LatestRelease_NoMatchingAsset(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"tag_name": "v0.3.0",
			"assets":   []map[string]any{},
		})
	}))
	defer srv.Close()

	checker := updater.NewGitHubChecker(srv.URL)
	_, err := checker.LatestRelease("scry_2-v0.3.0-linux-x86_64.tar.gz")
	if err == nil {
		t.Fatal("expected error for missing asset, got nil")
	}
}

func TestGitHubChecker_LatestRelease_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	checker := updater.NewGitHubChecker(srv.URL)
	_, err := checker.LatestRelease("scry_2-v0.3.0-linux-x86_64.tar.gz")
	if err == nil {
		t.Fatal("expected error for 500 response, got nil")
	}
}
