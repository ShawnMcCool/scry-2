package updater_test

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"scry2/tray/updater"
)

func makeTarGz(t *testing.T, files map[string]string) string {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		hdr := &tar.Header{Name: name, Mode: 0755, Size: int64(len(content))}
		tw.WriteHeader(hdr)
		tw.Write([]byte(content))
	}
	tw.Close()
	gz.Close()

	f, err := os.CreateTemp("", "test-*.tar.gz")
	if err != nil {
		t.Fatal(err)
	}
	f.Write(buf.Bytes())
	f.Close()
	t.Cleanup(func() { os.Remove(f.Name()) })
	return f.Name()
}

func makeZip(t *testing.T, files map[string]string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, content := range files {
		w, _ := zw.Create(name)
		w.Write([]byte(content))
	}
	zw.Close()

	f, err := os.CreateTemp("", "test-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	f.Write(buf.Bytes())
	f.Close()
	t.Cleanup(func() { os.Remove(f.Name()) })
	return f.Name()
}

func TestArchiveExtractor_TarGz(t *testing.T) {
	archive := makeTarGz(t, map[string]string{
		"install":       "#!/bin/sh\necho installed",
		"bin/scry_2":   "binary content",
	})
	dest := t.TempDir()

	e := updater.NewArchiveExtractor()
	if err := e.Extract(archive, dest); err != nil {
		t.Fatalf("Extract: %v", err)
	}

	content, err := os.ReadFile(filepath.Join(dest, "install"))
	if err != nil {
		t.Fatalf("install file not found: %v", err)
	}
	if string(content) != "#!/bin/sh\necho installed" {
		t.Errorf("unexpected install content: %q", content)
	}

	if runtime.GOOS != "windows" {
		info, err := os.Stat(filepath.Join(dest, "install"))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode()&0100 == 0 {
			t.Error("install file should be executable")
		}
	}
}

func TestArchiveExtractor_Zip(t *testing.T) {
	archive := makeZip(t, map[string]string{
		"install.bat":     "@echo off\necho installed",
		"bin/scry_2.bat": "bat content",
	})
	dest := t.TempDir()

	e := updater.NewArchiveExtractor()
	if err := e.Extract(archive, dest); err != nil {
		t.Fatalf("Extract: %v", err)
	}

	content, err := os.ReadFile(filepath.Join(dest, "install.bat"))
	if err != nil {
		t.Fatalf("install.bat not found: %v", err)
	}
	if string(content) != "@echo off\necho installed" {
		t.Errorf("unexpected install.bat content: %q", content)
	}
}

func TestArchiveExtractor_UnknownFormat(t *testing.T) {
	f, err := os.CreateTemp("", "test-*.bz2")
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("not a valid archive")
	f.Close()
	defer os.Remove(f.Name())

	e := updater.NewArchiveExtractor()
	if err := e.Extract(f.Name(), t.TempDir()); err == nil {
		t.Fatal("expected error for unknown format")
	}
}
