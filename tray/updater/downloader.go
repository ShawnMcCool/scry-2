package updater

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

// Downloader fetches a remote archive to a local temp file.
type Downloader interface {
	// Fetch downloads the archive at url and returns the path to a temp file.
	// The caller is responsible for removing the file when done.
	Fetch(url string) (path string, err error)
}

// HTTPDownloader downloads archives over HTTP using the stdlib client.
type HTTPDownloader struct{}

func NewHTTPDownloader() *HTTPDownloader { return &HTTPDownloader{} }

func (d *HTTPDownloader) Fetch(url string) (string, error) {
	resp, err := http.Get(url) //nolint:noctx
	if err != nil {
		return "", fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download %s: status %d", url, resp.StatusCode)
	}

	tmp, err := os.CreateTemp("", "scry2-update-*")
	if err != nil {
		return "", fmt.Errorf("create temp file: %w", err)
	}
	defer tmp.Close()

	if _, err := io.Copy(tmp, resp.Body); err != nil {
		os.Remove(tmp.Name())
		return "", fmt.Errorf("write download: %w", err)
	}

	return tmp.Name(), nil
}
