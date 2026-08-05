package importer

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestReadZipInputResolvesExplicitLinksAndReportsAssets(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "vault.zip")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entries := map[string]string{
		"Vault/":                 "",
		"Vault/A.md":             "See [[B]] and [C](/folder/C.md). ![image](assets/photo.png) and [site](//example.com/page).",
		"Vault/B.md":             "B body",
		"Vault/folder/C.md":      "C body",
		"Vault/assets/photo.png": "not-an-image-for-this-parser-test",
	}
	for name, body := range entries {
		entry, createErr := writer.Create(name)
		if createErr != nil {
			t.Fatal(createErr)
		}
		if _, writeErr := entry.Write([]byte(body)); writeErr != nil {
			t.Fatal(writeErr)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	parsed, err := readInput(
		"vault.zip", archivePath, "application/zip",
		uuid.New(), uuid.New(), time.UTC, 32<<20,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.Notes) != 3 {
		t.Fatalf("notes = %d, want 3", len(parsed.Notes))
	}
	if parsed.Skipped != 1 {
		t.Fatalf("skipped = %d, want 1 unsupported asset", parsed.Skipped)
	}
	var aNote *note
	for index := range parsed.Notes {
		if parsed.Notes[index].Path == "A.md" {
			aNote = &parsed.Notes[index]
			break
		}
	}
	if aNote == nil || len(aNote.Targets) != 2 {
		t.Fatalf("A note = %+v, want 2 targets", aNote)
	}
	issues := parsed.Issues.list()
	if len(issues) != 2 || !hasIssue(issues, "unsupported_file") || !hasIssue(issues, "unresolved_local_asset") {
		t.Fatalf("issues = %+v", issues)
	}
}

func TestReadZipInputResolvesExactExtensionsAndAliases(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "links.zip")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entries := map[string]string{
		"A.md":  "Markdown target",
		"A.txt": "Text target",
		"B.md":  "---\naliases: [Kyoto]\n---\nAlias target",
		"S.md":  "[md](A.md) [txt](A.txt) [[Kyoto]]",
	}
	for name, body := range entries {
		entry, createErr := writer.Create(name)
		if createErr != nil {
			t.Fatal(createErr)
		}
		if _, writeErr := entry.Write([]byte(body)); writeErr != nil {
			t.Fatal(writeErr)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	parsed, err := readInput("links.zip", archivePath, "application/zip", uuid.New(), uuid.New(), time.UTC, 32<<20)
	if err != nil {
		t.Fatal(err)
	}
	for _, importedNote := range parsed.Notes {
		if importedNote.Path == "S.md" && len(importedNote.Targets) != 3 {
			t.Fatalf("source targets = %d, want 3", len(importedNote.Targets))
		}
	}
}

func TestResolveLinksRejectsReferenceFlood(t *testing.T) {
	links := strings.Repeat("[[missing]] ", maxImportLinkRefs+1)
	notes := []note{{ID: uuid.New(), Path: "source.md", RawText: links}}
	if err := resolveLinks(notes, newIssueCollector()); err == nil {
		t.Fatal("link reference flood was accepted")
	}
}

func TestReadZipInputRejectsTraversal(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "bad.zip")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entry, err := writer.Create("../escape.md")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("escape")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	_, err = readInput("bad.zip", archivePath, "application/zip", uuid.New(), uuid.New(), time.UTC, 32<<20)
	if err == nil {
		t.Fatal("path traversal ZIP was accepted")
	}
}
