package objectstore

import (
	"context"

	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// Client is the subset of the AWS S3 client shared by Chronicle's upload,
// transcription, archive, and media-cleanup paths.
type Client interface {
	PutObject(ctx context.Context, input *s3.PutObjectInput, opts ...func(*s3.Options)) (*s3.PutObjectOutput, error)
	GetObject(ctx context.Context, input *s3.GetObjectInput, opts ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	DeleteObject(ctx context.Context, input *s3.DeleteObjectInput, opts ...func(*s3.Options)) (*s3.DeleteObjectOutput, error)
}
