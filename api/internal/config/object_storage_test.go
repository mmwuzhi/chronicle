package config

import "testing"

func TestResolveObjectStoragePrefersGenericS3(t *testing.T) {
	cfg := &Config{
		ObjectStorageEndpoint:  "http://minio:9000/",
		ObjectStorageRegion:    "us-east-1",
		ObjectStorageBucket:    "chronicle",
		ObjectStorageAccessKey: "access",
		ObjectStorageSecretKey: "secret",
		ObjectStoragePublicURL: "https://chronicle.example/media/",
		ObjectStoragePathStyle: true,
		R2BucketName:           "legacy",
		R2AccountID:            "account",
		R2AccessKey:            "legacy-access",
		R2SecretKey:            "legacy-secret",
	}
	settings, enabled, err := cfg.ResolveObjectStorage()
	if err != nil {
		t.Fatal(err)
	}
	if !enabled || settings.Provider != "s3" {
		t.Fatalf("generic storage not enabled: %+v", settings)
	}
	if settings.Endpoint != "http://minio:9000" ||
		settings.PublicBaseURL != "https://chronicle.example/media" ||
		!settings.ForcePathStyle {
		t.Fatalf("generic settings were not normalized: %+v", settings)
	}
}

func TestResolveObjectStorageR2Compatibility(t *testing.T) {
	cfg := &Config{
		R2BucketName: "chronicle",
		R2AccountID:  "account",
		R2AccessKey:  "access",
		R2SecretKey:  "secret",
	}
	settings, enabled, err := cfg.ResolveObjectStorage()
	if err != nil {
		t.Fatal(err)
	}
	if !enabled || settings.Provider != "r2" {
		t.Fatalf("R2 storage not enabled: %+v", settings)
	}
	if settings.Endpoint != "https://account.r2.cloudflarestorage.com" ||
		settings.PublicBaseURL != "https://chronicle.account.r2.cloudflarestorage.com" {
		t.Fatalf("unexpected R2 settings: %+v", settings)
	}
}

func TestResolveObjectStorageRejectsPartialConfiguration(t *testing.T) {
	cfg := &Config{ObjectStorageEndpoint: "http://minio:9000"}
	if _, _, err := cfg.ResolveObjectStorage(); err == nil {
		t.Fatal("partial generic storage config was accepted")
	}
	cfg = &Config{R2BucketName: "chronicle"}
	if _, _, err := cfg.ResolveObjectStorage(); err == nil {
		t.Fatal("partial R2 config was accepted")
	}
}
