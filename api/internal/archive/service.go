package archive

import (
	"archive/zip"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/objectstore"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

type Config struct {
	BucketName    string
	PublicBaseURL string
	MaxBytes      int64
}

type Service struct {
	pool *pgxpool.Pool
	q    *db.Queries
	s3   objectstore.Client
	cfg  Config
	rag  *ragclient.Client
}

type ExportFile struct {
	Path     string
	Filename string
}

type ImportResult struct {
	Created          int      `json:"created"`
	Skipped          int      `json:"skipped"`
	Forked           int      `json:"forked"`
	Media            int      `json:"media"`
	Links            int      `json:"links"`
	Attachments      int      `json:"attachments"`
	Warnings         []string `json:"warnings"`
	CreatedCaptureID []string `json:"createdCaptureIds"`
}

type archiveData struct {
	manifest Manifest
	files    map[string]*zip.File
	reader   *zip.ReadCloser
}

type importDecision struct {
	sourceID uuid.UUID
	targetID uuid.UUID
	create   bool
	forked   bool
	active   bool
	mediaKey string
	mediaURL string
}

type ImportError struct {
	Status int
	Title  string
	Err    error
}

func (e *ImportError) Error() string {
	if e.Err == nil {
		return e.Title
	}
	return e.Title + ": " + e.Err.Error()
}

func (e *ImportError) Unwrap() error {
	return e.Err
}

func NewService(pool *pgxpool.Pool, store objectstore.Client, cfg Config, rag *ragclient.Client) *Service {
	return &Service{
		pool: pool,
		q:    db.New(pool),
		s3:   store,
		cfg:  cfg,
		rag:  rag,
	}
}
