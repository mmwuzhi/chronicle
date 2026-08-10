package archive

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"

	"github.com/sikaoshenmi/chronicle/internal/upload"
)

var safeExtension = regexp.MustCompile(`^\.[a-zA-Z0-9]{1,10}$`)

const (
	maxArchiveEntries      = 60_000
	maxArchiveRecords      = 50_000
	maxArchiveControlBytes = 8 << 20
	maxArchiveRecordBytes  = 8 << 20
)

func detectArchiveMedia(file *zip.File) (string, string, error) {
	reader, err := file.Open()
	if err != nil {
		return "", "", err
	}
	header, readErr := io.ReadAll(io.LimitReader(reader, 512))
	closeErr := reader.Close()
	if readErr != nil {
		return "", "", readErr
	}
	if closeErr != nil {
		return "", "", closeErr
	}
	contentType, mediaType := upload.DetectMedia(header)
	if contentType == "" || mediaType == "" {
		return "", "", errors.New("archive contains unsupported media bytes")
	}
	return contentType, mediaType, nil
}

func preflightZipEntryCount(filename string) error {
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer file.Close()
	stat, err := file.Stat()
	if err != nil {
		return err
	}
	const (
		endRecordSize  = int64(22)
		maxCommentSize = int64(1<<16 - 1)
	)
	if stat.Size() < endRecordSize {
		return errors.New("archive is missing its ZIP end record")
	}
	tailSize := min(stat.Size(), endRecordSize+maxCommentSize)
	tail := make([]byte, tailSize)
	if _, err := file.ReadAt(tail, stat.Size()-tailSize); err != nil {
		return err
	}
	for index := len(tail) - int(endRecordSize); index >= 0; index-- {
		if binary.LittleEndian.Uint32(tail[index:index+4]) != 0x06054b50 {
			continue
		}
		commentLength := int(binary.LittleEndian.Uint16(tail[index+20 : index+22]))
		if index+int(endRecordSize)+commentLength != len(tail) {
			continue
		}
		if binary.LittleEndian.Uint16(tail[index+4:index+6]) != 0 ||
			binary.LittleEndian.Uint16(tail[index+6:index+8]) != 0 {
			return errors.New("multi-disk ZIP archives are not supported")
		}
		entriesOnDisk := binary.LittleEndian.Uint16(tail[index+8 : index+10])
		totalEntries := binary.LittleEndian.Uint16(tail[index+10 : index+12])
		if entriesOnDisk != totalEntries {
			return errors.New("ZIP entry count is inconsistent")
		}
		if totalEntries == 0xffff || int(totalEntries) > maxArchiveEntries {
			return errors.New("archive contains too many entries")
		}
		return nil
	}
	return errors.New("archive is missing its ZIP end record")
}

func forEachNDJSON[T CaptureRecord | LinkRecord | AttachmentRecord | RetrievalDismissalRecord](
	file *zip.File,
	visit func(T) error,
) error {
	reader, err := file.Open()
	if err != nil {
		return err
	}
	defer reader.Close()
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), maxArchiveRecordBytes)
	for scanner.Scan() {
		var record T
		if err := strictJSON(scanner.Bytes(), &record); err != nil {
			return err
		}
		if err := visit(record); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func strictJSON(data []byte, target interface{}) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("JSON entry contains trailing data")
	}
	return nil
}

func addZipBytes(writer *zip.Writer, name string, data []byte, checksums map[string]string) error {
	sum, err := addZipReader(writer, name, bytes.NewReader(data))
	if err != nil {
		return err
	}
	checksums[name] = sum
	return nil
}

func addZipReader(writer *zip.Writer, name string, reader io.Reader) (string, error) {
	header := &zip.FileHeader{Name: name, Method: zip.Deflate}
	header.SetMode(0o600)
	entry, err := writer.CreateHeader(header)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(entry, hash), reader); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func addZipGenerated(
	writer *zip.Writer,
	name string,
	generate func(io.Writer) error,
) (string, error) {
	header := &zip.FileHeader{Name: name, Method: zip.Deflate}
	header.SetMode(0o600)
	entry, err := writer.CreateHeader(header)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	if err := generate(io.MultiWriter(entry, hash)); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func readZipBytes(file *zip.File, maxBytes int64) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	limit := maxBytes
	if limit <= 0 {
		limit = 2 << 30
	}
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("archive entry exceeds the configured limit")
	}
	return data, nil
}

func hashZipFile(file *zip.File) (string, error) {
	reader, err := file.Open()
	if err != nil {
		return "", err
	}
	defer reader.Close()
	return hashReader(reader)
}

func hashReader(reader io.Reader) (string, error) {
	hash := sha256.New()
	if _, err := io.Copy(hash, reader); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func mediaExtension(mediaKey string) string {
	extension := path.Ext(mediaKey)
	if safeExtension.MatchString(extension) {
		return strings.ToLower(extension)
	}
	return ".bin"
}

func restoredMediaKey(userID, captureID, claimToken uuid.UUID, digest, contentType string) string {
	extension := restoredMediaExtension(contentType)
	return fmt.Sprintf(
		"archive-imports/%s/%s/%s-%s%s",
		userID,
		claimToken,
		captureID,
		digest[:16],
		extension,
	)
}

func restoredMediaExtension(contentType string) string {
	switch strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0])) {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "image/heic":
		return ".heic"
	case "image/avif":
		return ".avif"
	case "audio/mpeg":
		return ".mp3"
	case "audio/mp4":
		return ".m4a"
	case "audio/wav":
		return ".wav"
	case "audio/aiff":
		return ".aiff"
	case "audio/flac":
		return ".flac"
	case "audio/ogg", "video/ogg":
		return ".ogg"
	case "video/webm":
		return ".webm"
	default:
		return ".bin"
	}
}

func publicObjectURL(baseURL, key string) (string, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", errors.New("object storage public base URL is invalid")
	}
	return url.JoinPath(strings.TrimRight(baseURL, "/"), key)
}

func (s *Service) cleanupStagedMedia(keys []string) {
	if s.s3 == nil || s.cfg.BucketName == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, key := range keys {
		_, _ = s.s3.DeleteObject(ctx, &s3.DeleteObjectInput{
			Bucket: aws.String(s.cfg.BucketName),
			Key:    aws.String(key),
		})
		if ctx.Err() != nil {
			return
		}
	}
}
