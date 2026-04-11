package updater

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Extractor unpacks a downloaded archive into a destination directory.
type Extractor interface {
	Extract(archivePath, destDir string) error
}

// ArchiveExtractor handles tar.gz (Linux/macOS) and zip (Windows) archives.
type ArchiveExtractor struct{}

func NewArchiveExtractor() *ArchiveExtractor { return &ArchiveExtractor{} }

func (e *ArchiveExtractor) Extract(archivePath, destDir string) error {
	switch {
	case strings.HasSuffix(archivePath, ".tar.gz"):
		return extractTarGz(archivePath, destDir)
	case strings.HasSuffix(archivePath, ".zip"):
		return extractZip(archivePath, destDir)
	default:
		return fmt.Errorf("unsupported archive format: %s", archivePath)
	}
}

func extractTarGz(archivePath, destDir string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()

	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("gzip reader: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("tar read: %w", err)
		}
		if err := extractTarEntry(tr, hdr, destDir); err != nil {
			return err
		}
	}
	return nil
}

func extractTarEntry(r io.Reader, hdr *tar.Header, destDir string) error {
	// Strip the top-level directory component (e.g. "scry_2-v0.3.0-linux-x86_64/install" → "install").
	parts := strings.SplitN(hdr.Name, "/", 2)
	name := hdr.Name
	if len(parts) == 2 {
		name = parts[1]
	}
	if name == "" {
		return nil
	}

	target := filepath.Join(destDir, filepath.FromSlash(name))

	switch hdr.Typeflag {
	case tar.TypeDir:
		return os.MkdirAll(target, 0755)
	case tar.TypeReg:
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode)|0600)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(f, r)
		return err
	}
	return nil
}

func extractZip(archivePath, destDir string) error {
	zr, err := zip.OpenReader(archivePath)
	if err != nil {
		return fmt.Errorf("zip open: %w", err)
	}
	defer zr.Close()

	for _, entry := range zr.File {
		// Strip top-level directory component.
		parts := strings.SplitN(entry.Name, "/", 2)
		name := entry.Name
		if len(parts) == 2 {
			name = parts[1]
		}
		if name == "" {
			continue
		}

		target := filepath.Join(destDir, filepath.FromSlash(name))

		if entry.FileInfo().IsDir() {
			os.MkdirAll(target, 0755)
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		rc, err := entry.Open()
		if err != nil {
			return err
		}
		f, err := os.Create(target)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(f, rc)
		f.Close()
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}
