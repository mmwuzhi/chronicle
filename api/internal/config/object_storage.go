package config

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
)

type ObjectStorage struct {
	Endpoint       string
	Region         string
	Bucket         string
	AccessKey      string
	SecretKey      string
	PublicBaseURL  string
	ForcePathStyle bool
	Provider       string
}

func (cfg *Config) ResolveObjectStorage() (ObjectStorage, bool, error) {
	genericValues := []string{
		cfg.ObjectStorageEndpoint,
		cfg.ObjectStorageBucket,
		cfg.ObjectStorageAccessKey,
		cfg.ObjectStorageSecretKey,
		cfg.ObjectStoragePublicURL,
	}
	if hasAnyValue(genericValues) {
		if !hasEveryValue(genericValues) {
			return ObjectStorage{}, false, errors.New(
				"OBJECT_STORAGE_ENDPOINT, OBJECT_STORAGE_BUCKET, OBJECT_STORAGE_ACCESS_KEY, " +
					"OBJECT_STORAGE_SECRET_KEY, and OBJECT_STORAGE_PUBLIC_BASE_URL must be configured together",
			)
		}
		if err := validateHTTPURL(cfg.ObjectStorageEndpoint, "OBJECT_STORAGE_ENDPOINT"); err != nil {
			return ObjectStorage{}, false, err
		}
		if err := validateHTTPURL(cfg.ObjectStoragePublicURL, "OBJECT_STORAGE_PUBLIC_BASE_URL"); err != nil {
			return ObjectStorage{}, false, err
		}
		return ObjectStorage{
			Endpoint:       strings.TrimRight(cfg.ObjectStorageEndpoint, "/"),
			Region:         cfg.ObjectStorageRegion,
			Bucket:         cfg.ObjectStorageBucket,
			AccessKey:      cfg.ObjectStorageAccessKey,
			SecretKey:      cfg.ObjectStorageSecretKey,
			PublicBaseURL:  strings.TrimRight(cfg.ObjectStoragePublicURL, "/"),
			ForcePathStyle: cfg.ObjectStoragePathStyle,
			Provider:       "s3",
		}, true, nil
	}

	r2Values := []string{
		cfg.R2BucketName,
		cfg.R2AccountID,
		cfg.R2AccessKey,
		cfg.R2SecretKey,
	}
	if !hasAnyValue(r2Values) {
		return ObjectStorage{}, false, nil
	}
	if !hasEveryValue(r2Values) {
		return ObjectStorage{}, false, errors.New(
			"R2_BUCKET_NAME, R2_ACCOUNT_ID, R2_ACCESS_KEY, and R2_SECRET_KEY must be configured together",
		)
	}
	return ObjectStorage{
		Endpoint: fmt.Sprintf(
			"https://%s.r2.cloudflarestorage.com",
			cfg.R2AccountID,
		),
		Region:    "auto",
		Bucket:    cfg.R2BucketName,
		AccessKey: cfg.R2AccessKey,
		SecretKey: cfg.R2SecretKey,
		PublicBaseURL: fmt.Sprintf(
			"https://%s.%s.r2.cloudflarestorage.com",
			cfg.R2BucketName,
			cfg.R2AccountID,
		),
		Provider: "r2",
	}, true, nil
}

func hasAnyValue(values []string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return true
		}
	}
	return false
}

func hasEveryValue(values []string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) == "" {
			return false
		}
	}
	return true
}

func validateHTTPURL(value, name string) error {
	parsed, err := url.Parse(value)
	if err != nil ||
		(parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Host == "" {
		return fmt.Errorf("%s must be an absolute http(s) URL", name)
	}
	return nil
}
