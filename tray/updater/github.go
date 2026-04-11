package updater

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// Release holds the version and download URL for a specific platform's archive.
type Release struct {
	Version    string
	ArchiveURL string
}

// ReleaseChecker fetches the latest release for a given archive filename.
type ReleaseChecker interface {
	// LatestRelease returns the latest release whose asset matches archiveName.
	LatestRelease(archiveName string) (Release, error)
}

// GitHubChecker fetches release info from the GitHub Releases API.
type GitHubChecker struct {
	apiURL string
}

// NewGitHubChecker creates a checker pointed at the given base URL.
// Pass the real GitHub API URL in production:
//
//	updater.NewGitHubChecker("https://api.github.com/repos/shawnmccool/scry_2/releases/latest")
func NewGitHubChecker(apiURL string) *GitHubChecker {
	return &GitHubChecker{apiURL: apiURL}
}

type githubRelease struct {
	TagName string        `json:"tag_name"`
	Assets  []githubAsset `json:"assets"`
}

type githubAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

func (c *GitHubChecker) LatestRelease(archiveName string) (Release, error) {
	resp, err := http.Get(c.apiURL) //nolint:noctx
	if err != nil {
		return Release{}, fmt.Errorf("github releases request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Release{}, fmt.Errorf("github releases returned %d", resp.StatusCode)
	}

	var gr githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&gr); err != nil {
		return Release{}, fmt.Errorf("github releases decode: %w", err)
	}

	for _, asset := range gr.Assets {
		if asset.Name == archiveName {
			return Release{Version: gr.TagName, ArchiveURL: asset.BrowserDownloadURL}, nil
		}
	}

	return Release{}, fmt.Errorf("no asset %q in release %s", archiveName, gr.TagName)
}
