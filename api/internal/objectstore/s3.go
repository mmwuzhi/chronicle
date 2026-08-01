package objectstore

import (
	"context"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/sikaoshenmi/chronicle/internal/config"
)

// New creates an S3-compatible client from the deployment's resolved storage
// settings. The returned concrete client is intentionally hidden behind Client
// so upload, archive, and deletion callers only depend on the operations they use.
func New(ctx context.Context, settings config.ObjectStorage) (Client, error) {
	awsConfig, err := awsconfig.LoadDefaultConfig(
		ctx,
		awsconfig.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider(
				settings.AccessKey,
				settings.SecretKey,
				"",
			),
		),
		awsconfig.WithRegion(settings.Region),
	)
	if err != nil {
		return nil, err
	}

	return s3.NewFromConfig(awsConfig, func(options *s3.Options) {
		options.BaseEndpoint = aws.String(settings.Endpoint)
		options.UsePathStyle = settings.ForcePathStyle
	}), nil
}
