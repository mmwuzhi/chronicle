package archive

import (
	"archive/zip"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"
	"time"

	capturelogic "github.com/sikaoshenmi/chronicle/internal/capture"
)

func readArchive(filename string, maxBytes int64) (*archiveData, error) {
	if err := preflightZipEntryCount(filename); err != nil {
		return nil, err
	}
	reader, err := zip.OpenReader(filename)
	if err != nil {
		return nil, err
	}
	success := false
	defer func() {
		if !success {
			_ = reader.Close()
		}
	}()

	if len(reader.File) > maxArchiveEntries {
		return nil, errors.New("archive contains too many entries")
	}
	files := make(map[string]*zip.File, len(reader.File))
	var uncompressed uint64
	for _, file := range reader.File {
		if !validEntryName(file.Name) || strings.HasSuffix(file.Name, "/") {
			return nil, fmt.Errorf("invalid archive path %q", file.Name)
		}
		if !file.Mode().IsRegular() {
			return nil, fmt.Errorf("archive entry %q is not a regular file", file.Name)
		}
		if _, exists := files[file.Name]; exists {
			return nil, fmt.Errorf("archive entry %q is duplicated", file.Name)
		}
		if ^uint64(0)-uncompressed < file.UncompressedSize64 {
			return nil, errors.New("archive uncompressed size overflow")
		}
		uncompressed += file.UncompressedSize64
		if maxBytes > 0 && uncompressed > uint64(maxBytes) {
			return nil, errors.New("archive uncompressed content exceeds the configured limit")
		}
		files[file.Name] = file
	}
	for _, required := range []string{
		manifestPath, capturesPath, linksPath, attachmentsPath, notesPath, checksumsPath,
	} {
		if files[required] == nil {
			return nil, fmt.Errorf("required entry %q is missing", required)
		}
	}

	checksumBytes, err := readZipBytes(files[checksumsPath], maxArchiveControlBytes)
	if err != nil {
		return nil, err
	}
	checksums, err := parseChecksums(checksumBytes)
	if err != nil {
		return nil, err
	}
	if len(checksums) != len(files)-1 {
		return nil, errors.New("checksum list does not cover every archive entry")
	}
	for name, file := range files {
		if name == checksumsPath {
			continue
		}
		expected, exists := checksums[name]
		if !exists {
			return nil, fmt.Errorf("archive entry %q has no checksum", name)
		}
		actual, hashErr := hashZipFile(file)
		if hashErr != nil {
			return nil, hashErr
		}
		if actual != expected {
			return nil, fmt.Errorf("archive entry %q failed checksum validation", name)
		}
	}

	manifestBytes, err := readZipBytes(files[manifestPath], maxArchiveControlBytes)
	if err != nil {
		return nil, err
	}
	var manifest Manifest
	if err := strictJSON(manifestBytes, &manifest); err != nil {
		return nil, err
	}
	if manifest.Format != formatName || manifest.FormatVersion != formatVersion {
		return nil, fmt.Errorf("unsupported archive format %q version %d", manifest.Format, manifest.FormatVersion)
	}
	if !manifest.IncludesTrash || !manifest.MediaComplete {
		return nil, errors.New("archive is not marked complete")
	}
	if _, err := time.Parse(time.RFC3339Nano, manifest.ExportedAt); err != nil {
		return nil, errors.New("manifest exportedAt is invalid")
	}
	for name, count := range map[string]int{
		"captures":    manifest.Counts.Captures,
		"links":       manifest.Counts.Links,
		"attachments": manifest.Counts.Attachments,
		"media":       manifest.Counts.Media,
	} {
		if count < 0 || count > maxArchiveRecords {
			return nil, fmt.Errorf("manifest %s count is out of range", name)
		}
	}

	data := &archiveData{
		manifest: manifest,
		files:    files,
		reader:   reader,
	}
	if err := validateArchiveRecords(data); err != nil {
		return nil, err
	}
	success = true
	return data, nil
}

func validateArchiveRecords(data *archiveData) error {
	captureIDs := make(map[string]struct{}, data.manifest.Counts.Captures)
	mediaPaths := make(map[string]struct{})
	captureCount := 0
	err := forEachNDJSON(data.files[capturesPath], func(record CaptureRecord) error {
		index := captureCount
		captureCount++
		if _, err := validateUUID(record.ID, fmt.Sprintf("capture %d id", index)); err != nil {
			return err
		}
		if _, exists := captureIDs[record.ID]; exists {
			return fmt.Errorf("capture id %q is duplicated", record.ID)
		}
		captureIDs[record.ID] = struct{}{}
		if !slices.Contains([]string{"text", "image", "audio"}, record.MediaType) {
			return fmt.Errorf("capture %s has invalid mediaType", record.ID)
		}
		rawText := ""
		if record.RawText != nil {
			rawText = *record.RawText
		}
		if record.MediaType == "text" && strings.TrimSpace(rawText) == "" {
			return fmt.Errorf("capture %s has empty text content", record.ID)
		}
		if _, err := capturelogic.NormalizeSource(record.Source); err != nil {
			return fmt.Errorf("capture %s has invalid source", record.ID)
		}
		if !slices.Contains([]string{"task", "idea", "routine", "log", "unclassified"}, record.ClassifiedAs) {
			return fmt.Errorf("capture %s has invalid classifiedAs", record.ID)
		}
		if !slices.Contains([]string{"none", "pending", "processing", "completed", "failed", "skipped"}, record.TranscriptionStatus) {
			return fmt.Errorf("capture %s has invalid transcriptionStatus", record.ID)
		}
		if record.TranscriptionAttempts < 0 || record.TranscriptionAttempts > 8 {
			return fmt.Errorf("capture %s has invalid transcriptionAttempts", record.ID)
		}
		if record.DoneAt != nil && record.TodoAt == nil {
			return fmt.Errorf("capture %s has doneAt without todoAt", record.ID)
		}
		todoReference := time.Now()
		if record.TodoAt != nil {
			todoReference, _ = time.Parse(time.RFC3339Nano, *record.TodoAt)
		}
		derivedTodo, derivedDone := capturelogic.DeriveTodoStamps(rawText, todoReference)
		if derivedTodo.Valid != (record.TodoAt != nil) ||
			derivedDone.Valid != (record.DoneAt != nil) {
			return fmt.Errorf("capture %s todo fields do not match its text", record.ID)
		}
		for name, timestamp := range map[string]*string{
			"createdAt":           &record.CreatedAt,
			"transcribedAt":       record.TranscribedAt,
			"nextTranscriptionAt": record.NextTranscriptionAt,
			"remindAt":            record.RemindAt,
			"deletedAt":           record.DeletedAt,
			"todoAt":              record.TodoAt,
			"doneAt":              record.DoneAt,
		} {
			if timestamp != nil {
				if _, err := time.Parse(time.RFC3339Nano, *timestamp); err != nil {
					return fmt.Errorf("capture %s has invalid %s", record.ID, name)
				}
			}
		}
		mediaFieldCount := 0
		for _, value := range []*string{record.MediaPath, record.MediaSHA256, record.MediaContentType} {
			if value != nil {
				mediaFieldCount++
			}
		}
		if mediaFieldCount != 0 && mediaFieldCount != 3 {
			return fmt.Errorf("capture %s has incomplete media metadata", record.ID)
		}
		if record.LegacyMediaURL != nil {
			return fmt.Errorf("capture %s references legacy external media", record.ID)
		}
		if record.MediaType == "text" && mediaFieldCount != 0 {
			return fmt.Errorf("text capture %s unexpectedly contains media bytes", record.ID)
		}
		if record.MediaType != "text" && mediaFieldCount != 3 {
			return fmt.Errorf("media capture %s is missing complete media bytes", record.ID)
		}
		if record.MediaPath != nil {
			if !strings.HasPrefix(*record.MediaPath, "media/") || data.files[*record.MediaPath] == nil {
				return fmt.Errorf("capture %s references missing media", record.ID)
			}
			if _, duplicate := mediaPaths[*record.MediaPath]; duplicate {
				return fmt.Errorf("media path %q is referenced more than once", *record.MediaPath)
			}
			mediaPaths[*record.MediaPath] = struct{}{}
			if len(*record.MediaSHA256) != sha256.Size*2 {
				return fmt.Errorf("capture %s has invalid mediaSha256", record.ID)
			}
			actual, err := hashZipFile(data.files[*record.MediaPath])
			if err != nil {
				return err
			}
			if actual != strings.ToLower(*record.MediaSHA256) {
				return fmt.Errorf("capture %s media digest does not match", record.ID)
			}
			_, mediaType, err := detectArchiveMedia(data.files[*record.MediaPath])
			if err != nil {
				return err
			}
			if mediaType != record.MediaType {
				return fmt.Errorf("capture %s media bytes do not match mediaType", record.ID)
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if captureCount != data.manifest.Counts.Captures {
		return errors.New("manifest capture count does not match archive data")
	}
	if data.manifest.Counts.Media != len(mediaPaths) {
		return errors.New("manifest media count does not match archive data")
	}
	for name := range data.files {
		if strings.HasPrefix(name, "media/") {
			if _, referenced := mediaPaths[name]; !referenced {
				return fmt.Errorf("media entry %q is not referenced by a capture", name)
			}
		}
	}
	linkKeys := make(map[string]struct{}, data.manifest.Counts.Links)
	linkCount := 0
	err = forEachNDJSON(data.files[linksPath], func(link LinkRecord) error {
		linkCount++
		if link.AID == link.BID {
			return errors.New("archive contains a self-link")
		}
		if _, exists := captureIDs[link.AID]; !exists {
			return fmt.Errorf("link references unknown capture %s", link.AID)
		}
		if _, exists := captureIDs[link.BID]; !exists {
			return fmt.Errorf("link references unknown capture %s", link.BID)
		}
		if _, err := time.Parse(time.RFC3339Nano, link.CreatedAt); err != nil {
			return errors.New("link createdAt is invalid")
		}
		key := link.AID + ":" + link.BID
		if link.BID < link.AID {
			key = link.BID + ":" + link.AID
		}
		if _, duplicated := linkKeys[key]; duplicated {
			return fmt.Errorf("capture link %q is duplicated", key)
		}
		linkKeys[key] = struct{}{}
		return nil
	})
	if err != nil {
		return err
	}
	if linkCount != data.manifest.Counts.Links {
		return errors.New("manifest link count does not match archive data")
	}
	attachmentIDs := make(map[string]struct{}, data.manifest.Counts.Attachments)
	attachmentCount := 0
	err = forEachNDJSON(data.files[attachmentsPath], func(attachment AttachmentRecord) error {
		attachmentCount++
		if _, err := validateUUID(attachment.ID, "attachment id"); err != nil {
			return err
		}
		if _, duplicated := attachmentIDs[attachment.ID]; duplicated {
			return fmt.Errorf("attachment id %q is duplicated", attachment.ID)
		}
		attachmentIDs[attachment.ID] = struct{}{}
		if _, exists := captureIDs[attachment.CaptureID]; !exists {
			return fmt.Errorf("attachment references unknown capture %s", attachment.CaptureID)
		}
		if !slices.Contains([]string{"google_drive", "onedrive", "dropbox"}, attachment.Provider) {
			return fmt.Errorf("attachment %s has invalid provider", attachment.ID)
		}
		if strings.TrimSpace(attachment.ProviderFileID) == "" ||
			strings.TrimSpace(attachment.Name) == "" ||
			strings.TrimSpace(attachment.WebURL) == "" {
			return fmt.Errorf("attachment %s has an empty required field", attachment.ID)
		}
		attachmentURL, err := url.Parse(attachment.WebURL)
		if err != nil ||
			len(attachment.WebURL) > 2048 ||
			(attachmentURL.Scheme != "https" && attachmentURL.Scheme != "http") ||
			attachmentURL.Host == "" {
			return fmt.Errorf("attachment %s has an invalid webURL", attachment.ID)
		}
		if attachment.SizeBytes != nil && *attachment.SizeBytes < 0 {
			return fmt.Errorf("attachment %s has a negative size", attachment.ID)
		}
		if _, err := time.Parse(time.RFC3339Nano, attachment.CreatedAt); err != nil {
			return fmt.Errorf("attachment %s has invalid createdAt", attachment.ID)
		}
		if attachment.DeletedAt != nil {
			if _, err := time.Parse(time.RFC3339Nano, *attachment.DeletedAt); err != nil {
				return fmt.Errorf("attachment %s has invalid deletedAt", attachment.ID)
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if attachmentCount != data.manifest.Counts.Attachments {
		return errors.New("manifest attachment count does not match archive data")
	}
	return nil
}
