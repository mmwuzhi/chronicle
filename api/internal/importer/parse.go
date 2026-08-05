package importer

import (
	"archive/zip"
	"crypto/sha256"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

var (
	markdownLinkPattern = regexp.MustCompile(`(!?)\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)`)
	wikiLinkPattern     = regexp.MustCompile(`\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]`)
)

func readInput(
	filename, inputPath, contentType string,
	userID, operationID uuid.UUID,
	location *time.Location,
	maxBytes int64,
) (*parsedInput, error) {
	extension := strings.ToLower(path.Ext(filename))
	if extension == ".zip" || contentType == "application/zip" {
		return readZipInput(inputPath, userID, operationID, location, maxBytes)
	}
	if !supportedTextExtension(extension) {
		return nil, fmt.Errorf("unsupported import file extension %q", extension)
	}
	stat, err := os.Stat(inputPath)
	if err != nil {
		return nil, err
	}
	if stat.Size() > maxImportNoteBytes {
		return nil, fmt.Errorf("text file exceeds the %d byte limit", maxImportNoteBytes)
	}
	data, err := os.ReadFile(inputPath)
	if err != nil {
		return nil, err
	}
	issues := newIssueCollector()
	importedNote, applied, ok := parseTextFile(filename, data, userID, operationID, location, issues)
	if !ok {
		return nil, errNoImportableNotes
	}
	return &parsedInput{
		Notes:              []note{importedNote},
		Issues:             issues,
		FrontmatterApplied: boolInt(applied),
	}, nil
}

func readZipInput(
	inputPath string,
	userID, operationID uuid.UUID,
	location *time.Location,
	maxBytes int64,
) (*parsedInput, error) {
	reader, err := zip.OpenReader(inputPath)
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	if len(reader.File) > maxImportEntries {
		return nil, fmt.Errorf("ZIP contains more than %d entries", maxImportEntries)
	}
	files := make(map[string]*zip.File, len(reader.File))
	var expanded uint64
	for _, file := range reader.File {
		if !validImportPath(file.Name) {
			return nil, fmt.Errorf("invalid ZIP path %q", file.Name)
		}
		if _, duplicate := files[file.Name]; duplicate {
			return nil, fmt.Errorf("duplicate ZIP path %q", file.Name)
		}
		files[file.Name] = file
		if ^uint64(0)-expanded < file.UncompressedSize64 {
			return nil, fmt.Errorf("ZIP expanded size overflow")
		}
		expanded += file.UncompressedSize64
		if maxBytes > 0 && expanded > uint64(maxBytes) {
			return nil, fmt.Errorf("ZIP expanded content exceeds the configured limit")
		}
		if !file.FileInfo().IsDir() && !file.Mode().IsRegular() {
			return nil, fmt.Errorf("ZIP entry %q is not a regular file", file.Name)
		}
	}
	commonRoot := commonTopLevelRoot(reader.File)
	issues := newIssueCollector()
	notes := make([]note, 0)
	frontmatterCount := 0
	skipped := 0
	for _, file := range reader.File {
		if file.FileInfo().IsDir() || ignoredNoisePath(file.Name) {
			continue
		}
		normalizedPath := strings.TrimPrefix(file.Name, commonRoot)
		if !supportedTextExtension(strings.ToLower(path.Ext(normalizedPath))) {
			issues.add("unsupported_file", normalizedPath)
			skipped++
			continue
		}
		if len(notes) >= maxImportNotes {
			return nil, fmt.Errorf("ZIP contains more than %d importable notes", maxImportNotes)
		}
		if file.UncompressedSize64 > maxImportNoteBytes {
			issues.add("note_too_large", normalizedPath)
			skipped++
			continue
		}
		data, readErr := readZipFile(file)
		if readErr != nil {
			return nil, readErr
		}
		note, applied, ok := parseTextFile(normalizedPath, data, userID, operationID, location, issues)
		if !ok {
			skipped++
			continue
		}
		notes = append(notes, note)
		frontmatterCount += boolInt(applied)
	}
	if len(notes) == 0 {
		return nil, errNoImportableNotes
	}
	if err := resolveLinks(notes, issues); err != nil {
		return nil, err
	}
	return &parsedInput{
		Notes: notes, Issues: issues, FrontmatterApplied: frontmatterCount, Skipped: skipped,
	}, nil
}

func parseTextFile(
	filename string,
	data []byte,
	userID, operationID uuid.UUID,
	location *time.Location,
	issues *issueCollector,
) (note, bool, bool) {
	if !utf8.Valid(data) {
		issues.add("invalid_utf8", filename)
		return note{}, false, false
	}
	rawText, createdAt, aliases, linkText, applied := parseNote(filename, string(data), location, issues)
	if strings.TrimSpace(rawText) == "" {
		issues.add("empty_note", filename)
		return note{}, applied, false
	}
	return note{
		ID:        importedCaptureID(userID, operationID, filename),
		Path:      filename,
		RawText:   rawText,
		LinkText:  linkText,
		CreatedAt: createdAt,
		Aliases:   aliases,
	}, applied, true
}

func resolveLinks(notes []note, issues *issueCollector) error {
	byExactPath := make(map[string][]uuid.UUID, len(notes))
	byPathWithoutExtension := make(map[string][]uuid.UUID, len(notes))
	byName := make(map[string][]uuid.UUID, len(notes))
	for _, importedNote := range notes {
		byExactPath[importedNote.Path] = append(byExactPath[importedNote.Path], importedNote.ID)
		withoutExtension := strings.TrimSuffix(importedNote.Path, path.Ext(importedNote.Path))
		byPathWithoutExtension[withoutExtension] = append(byPathWithoutExtension[withoutExtension], importedNote.ID)
		stem := strings.TrimSuffix(path.Base(importedNote.Path), path.Ext(importedNote.Path))
		byName[stem] = append(byName[stem], importedNote.ID)
		for _, alias := range importedNote.Aliases {
			if normalized := strings.TrimSpace(alias); normalized != "" {
				byName[normalized] = append(byName[normalized], importedNote.ID)
			}
		}
	}
	references := 0
	links := 0
	for index := range notes {
		targets := make(map[uuid.UUID]struct{})
		linkText := notes[index].LinkText
		if linkText == "" {
			linkText = notes[index].RawText
		}
		remaining := maxImportLinkRefs - references
		matches := markdownLinkPattern.FindAllStringSubmatch(linkText, remaining+1)
		references += len(matches)
		if references > maxImportLinkRefs {
			return fmt.Errorf("import contains more than %d note-link references", maxImportLinkRefs)
		}
		for _, match := range matches {
			isImage := match[1] == "!"
			resolveImportedTarget(notes[index], match[2], false, isImage, byExactPath, byPathWithoutExtension, byName, targets, issues)
		}
		remaining = maxImportLinkRefs - references
		matches = wikiLinkPattern.FindAllStringSubmatch(linkText, remaining+1)
		references += len(matches)
		if references > maxImportLinkRefs {
			return fmt.Errorf("import contains more than %d note-link references", maxImportLinkRefs)
		}
		for _, match := range matches {
			resolveImportedTarget(notes[index], match[1], true, false, byExactPath, byPathWithoutExtension, byName, targets, issues)
		}
		delete(targets, notes[index].ID)
		links += len(targets)
		if links > maxImportLinks {
			return fmt.Errorf("import resolves more than %d Capture links", maxImportLinks)
		}
		for target := range targets {
			notes[index].Targets = append(notes[index].Targets, target)
		}
		slices.SortFunc(notes[index].Targets, func(a, b uuid.UUID) int {
			return strings.Compare(a.String(), b.String())
		})
	}
	return nil
}

func resolveImportedTarget(
	source note,
	rawTarget string,
	wiki, image bool,
	byExactPath map[string][]uuid.UUID,
	byPathWithoutExtension map[string][]uuid.UUID,
	byName map[string][]uuid.UUID,
	targets map[uuid.UUID]struct{},
	issues *issueCollector,
) {
	target := strings.Trim(strings.TrimSpace(rawTarget), "<>")
	if target == "" || strings.HasPrefix(target, "#") {
		return
	}
	if strings.HasPrefix(target, "//") {
		return
	}
	if parsed, err := url.Parse(target); err == nil && parsed.Scheme != "" {
		return
	}
	if marker := strings.IndexAny(target, "?#"); marker >= 0 {
		target = target[:marker]
	}
	if decoded, err := url.PathUnescape(target); err == nil {
		target = decoded
	}
	extension := strings.ToLower(path.Ext(target))
	if image || (extension != "" && !supportedTextExtension(extension)) {
		issues.add("unresolved_local_asset", source.Path+" -> "+rawTarget)
		return
	}
	relative := ""
	if strings.HasPrefix(target, "/") {
		relative = path.Clean(strings.TrimPrefix(target, "/"))
	} else {
		relative = path.Clean(path.Join(path.Dir(source.Path), target))
	}
	candidates := byExactPath[relative]
	if extension == "" {
		candidates = byPathWithoutExtension[relative]
	}
	candidates = uniqueUUIDs(candidates)
	if len(candidates) == 1 {
		targets[candidates[0]] = struct{}{}
		return
	}
	if len(candidates) > 1 {
		issues.add("ambiguous_link", source.Path+" -> "+rawTarget)
		return
	}
	if wiki && !strings.Contains(target, "/") {
		matches := uniqueUUIDs(byName[path.Base(target)])
		if len(matches) == 1 {
			targets[matches[0]] = struct{}{}
			return
		}
		if len(matches) > 1 {
			issues.add("ambiguous_link", source.Path+" -> "+rawTarget)
			return
		}
	}
	issues.add("unresolved_link", source.Path+" -> "+rawTarget)
}

func uniqueUUIDs(values []uuid.UUID) []uuid.UUID {
	if len(values) < 2 {
		return values
	}
	seen := make(map[uuid.UUID]struct{}, len(values))
	result := make([]uuid.UUID, 0, len(values))
	for _, value := range values {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func readZipFile(file *zip.File) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, maxImportNoteBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxImportNoteBytes {
		return nil, fmt.Errorf("ZIP entry %q exceeds the note size limit", file.Name)
	}
	return data, nil
}

func importedCaptureID(userID, operationID uuid.UUID, filename string) uuid.UUID {
	hash := sha256.Sum256([]byte(userID.String() + "\x00" + operationID.String() + "\x00" + filename))
	var id uuid.UUID
	copy(id[:], hash[:16])
	id[6] = (id[6] & 0x0f) | 0x50
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

func supportedTextExtension(extension string) bool {
	return extension == ".md" || extension == ".markdown" || extension == ".txt"
}

func validImportPath(name string) bool {
	if name == "" || !utf8.ValidString(name) || strings.HasPrefix(name, "/") || strings.Contains(name, "\\") {
		return false
	}
	cleanable := strings.TrimSuffix(name, "/")
	return cleanable != "" && path.Clean(cleanable) == cleanable &&
		cleanable != "." && !strings.HasPrefix(cleanable, "../")
}

func ignoredNoisePath(name string) bool {
	return strings.HasPrefix(name, "__MACOSX/") || path.Base(name) == ".DS_Store"
}

func commonTopLevelRoot(files []*zip.File) string {
	root := ""
	for _, file := range files {
		if ignoredNoisePath(file.Name) {
			continue
		}
		parts := strings.SplitN(file.Name, "/", 2)
		if len(parts) < 2 {
			return ""
		}
		if root == "" {
			root = parts[0]
		} else if root != parts[0] {
			return ""
		}
	}
	if root == "" {
		return ""
	}
	return root + "/"
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
