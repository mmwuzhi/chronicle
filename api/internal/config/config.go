package config

import (
	"log"

	"github.com/kelseyhightower/envconfig"
)

type Config struct {
	DatabaseURL  string `envconfig:"DATABASE_URL" required:"true"`
	RedisURL     string `envconfig:"REDIS_URL" required:"true"`
	JWTSecret    string `envconfig:"JWT_SECRET" required:"true"`
	R2BucketName string `envconfig:"R2_BUCKET_NAME"`
	R2AccountID  string `envconfig:"R2_ACCOUNT_ID"`
	R2AccessKey  string `envconfig:"R2_ACCESS_KEY"`
	R2SecretKey  string `envconfig:"R2_SECRET_KEY"`
	FrontendURL  string `envconfig:"FRONTEND_URL"`
	ResendAPIKey string `envconfig:"RESEND_API_KEY"`
	OpenAIKey    string `envconfig:"OPENAI_API_KEY"`
	Port         string `envconfig:"PORT" default:"8080"`
	Env          string `envconfig:"ENV" default:"development"`
}

func Load() *Config {
	var cfg Config
	if err := envconfig.Process("", &cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}
	return &cfg
}
