//go:build darwin || linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolvePayload(t *testing.T) {
	t.Setenv(payloadEnvironment, "")
	payload, args, err := resolvePayload([]string{"--payload", "/tmp/payload", "--", "version"})
	if err != nil {
		t.Fatal(err)
	}
	if payload != "/tmp/payload" || len(args) != 1 || args[0] != "version" {
		t.Fatalf("unexpected payload resolution: %q %#v", payload, args)
	}
}

func TestReadyRequiresOwnerOnlyRegularFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "ready")
	if err := os.WriteFile(path, []byte("ready\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !ready(path) {
		t.Fatal("owner-only regular marker should be ready")
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if ready(path) {
		t.Fatal("group/world-readable marker must not be ready")
	}
}

func TestCleanupExternalRemovesOnlyTheExactReleaseArgumentPath(t *testing.T) {
	dir, err := os.MkdirTemp("", "twelvgaige-release-cli.")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	file := filepath.Join(dir, "args")
	if err := os.WriteFile(file, []byte("version\x00"), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv(cleanupFileEnvironment, file)
	t.Setenv(cleanupDirEnvironment, dir)
	cleanupExternal()

	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatalf("argument file still exists: %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("argument directory still exists: %v", err)
	}
}
