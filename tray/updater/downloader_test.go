package updater_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"scry2/tray/updater"
)

func TestHTTPDownloader_Fetch_HappyPath(t *testing.T) {
	want := []byte("fake archive content")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(want)
	}))
	defer srv.Close()

	d := updater.NewHTTPDownloader()
	path, err := d.Fetch(srv.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer os.Remove(path)

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read temp file: %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("content mismatch: got %q, want %q", got, want)
	}
}

func TestHTTPDownloader_Fetch_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	d := updater.NewHTTPDownloader()
	_, err := d.Fetch(srv.URL)
	if err == nil {
		t.Fatal("expected error for 404, got nil")
	}
}
