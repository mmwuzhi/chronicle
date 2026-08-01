package objectstore

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/sikaoshenmi/chronicle/internal/config"
)

func TestNewAppliesResolvedS3Settings(t *testing.T) {
	client, err := New(context.Background(), config.ObjectStorage{
		Endpoint:       "https://storage.example.test",
		Region:         "test-region-1",
		AccessKey:      "access-key",
		SecretKey:      "secret-key",
		ForcePathStyle: true,
	})
	if err != nil {
		t.Fatal(err)
	}

	concrete, ok := client.(*s3.Client)
	if !ok {
		t.Fatalf("expected *s3.Client, got %T", client)
	}
	options := concrete.Options()
	if got := aws.ToString(options.BaseEndpoint); got != "https://storage.example.test" {
		t.Fatalf("expected configured endpoint, got %q", got)
	}
	if options.Region != "test-region-1" {
		t.Fatalf("expected configured region, got %q", options.Region)
	}
	if !options.UsePathStyle {
		t.Fatal("expected path-style addressing to be enabled")
	}
}
