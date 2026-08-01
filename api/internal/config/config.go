package config

import (
	"errors"
	"log"

	"github.com/kelseyhightower/envconfig"
)

type Config struct {
	DatabaseURL              string `envconfig:"DATABASE_URL" required:"true"`
	LegacyRedisURL           string `envconfig:"REDIS_URL" doc:"Temporary cross-release auth-state bridge; leave empty after the migration window"`
	JWTSecret                string `envconfig:"JWT_SECRET" required:"true"`
	R2BucketName             string `envconfig:"R2_BUCKET_NAME"`
	R2AccountID              string `envconfig:"R2_ACCOUNT_ID"`
	R2AccessKey              string `envconfig:"R2_ACCESS_KEY"`
	R2SecretKey              string `envconfig:"R2_SECRET_KEY"`
	ObjectStorageEndpoint    string `envconfig:"OBJECT_STORAGE_ENDPOINT"`
	ObjectStorageRegion      string `envconfig:"OBJECT_STORAGE_REGION" default:"us-east-1"`
	ObjectStorageBucket      string `envconfig:"OBJECT_STORAGE_BUCKET"`
	ObjectStorageAccessKey   string `envconfig:"OBJECT_STORAGE_ACCESS_KEY"`
	ObjectStorageSecretKey   string `envconfig:"OBJECT_STORAGE_SECRET_KEY"`
	ObjectStoragePublicURL   string `envconfig:"OBJECT_STORAGE_PUBLIC_BASE_URL"`
	ObjectStoragePathStyle   bool   `envconfig:"OBJECT_STORAGE_FORCE_PATH_STYLE"`
	FrontendURL              string `envconfig:"FRONTEND_URL"`
	APIBaseURL               string `envconfig:"API_BASE_URL" default:"http://localhost:8080"`
	ResendAPIKey             string `envconfig:"RESEND_API_KEY"`
	GoogleClientID           string `envconfig:"GOOGLE_CLIENT_ID"`
	GoogleClientSecret       string `envconfig:"GOOGLE_CLIENT_SECRET"`
	GitHubClientID           string `envconfig:"GITHUB_CLIENT_ID"`
	GitHubClientSecret       string `envconfig:"GITHUB_CLIENT_SECRET"`
	TurnstileSecret          string `envconfig:"TURNSTILE_SECRET_KEY"`
	WebAuthnRPID             string `envconfig:"WEBAUTHN_RP_ID" default:"localhost"`
	WebAuthnRPOrigin         string `envconfig:"WEBAUTHN_RP_ORIGIN" default:"http://localhost:5173"`
	OpenAIKey                string `envconfig:"OPENAI_API_KEY"`
	OpenAIBaseURL            string `envconfig:"OPENAI_BASE_URL" default:"https://api.openai.com/v1"`
	OpenAITranscriptionModel string `envconfig:"OPENAI_TRANSCRIPTION_MODEL" default:"gpt-4o-mini-transcribe"`
	OpenAIVisionModel        string `envconfig:"OPENAI_VISION_MODEL" default:"gpt-4o-mini"`
	VisionEnabled            bool   `envconfig:"VISION_ENABLED" doc:"Transcribe image captures to searchable text via the vision model; requires OPENAI_API_KEY"`
	LinkFetchEnabled         bool   `envconfig:"LINK_FETCH_ENABLED" doc:"Fetch the readable text of URLs in text captures into transcript so they are searchable by content; no external API key needed"`
	GeminiKey                string `envconfig:"GEMINI_API_KEY"`
	RAGServiceURL            string `envconfig:"RAG_SERVICE_URL" doc:"Base URL of the Python RAG sidecar; empty disables semantic recall"`
	ArchiveMaxBytes          int64  `envconfig:"ARCHIVE_MAX_BYTES" default:"2147483648" doc:"Maximum compressed and uncompressed archive import size in bytes"`
	Port                     string `envconfig:"PORT" default:"8080"`
	Env                      string `envconfig:"ENV" default:"development"`
}

func Load() *Config {
	var cfg Config
	if err := envconfig.Process("", &cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}
	if err := validate(&cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}
	return &cfg
}

func validate(cfg *Config) error {
	if cfg.ArchiveMaxBytes <= 0 {
		return errors.New("ARCHIVE_MAX_BYTES must be greater than zero")
	}
	return nil
}
