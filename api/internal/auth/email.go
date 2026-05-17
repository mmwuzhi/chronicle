package auth

import (
	"fmt"

	"github.com/resend/resend-go/v2"
)

func sendVerificationEmail(apiKey, frontendURL, to, token string) error {
	client := resend.NewClient(apiKey)
	link := fmt.Sprintf("%s/verify-email?token=%s", frontendURL, token)
	_, err := client.Emails.Send(&resend.SendEmailRequest{
		From:    "Chronicle <noreply@chronicle.wuwuwu.cc>",
		To:      []string{to},
		Subject: "Verify your Chronicle account",
		Html: fmt.Sprintf(`
<p>Thanks for signing up. Click the link below to verify your email address:</p>
<p><a href="%s">Verify email</a></p>
<p>This link expires in 24 hours. If you didn't create an account, ignore this email.</p>
`, link),
	})
	return err
}

func sendPasswordResetEmail(apiKey, frontendURL, to, token string) error {
	client := resend.NewClient(apiKey)
	link := fmt.Sprintf("%s/reset-password?token=%s", frontendURL, token)
	_, err := client.Emails.Send(&resend.SendEmailRequest{
		From:    "Chronicle <noreply@chronicle.wuwuwu.cc>",
		To:      []string{to},
		Subject: "Reset your Chronicle password",
		Html: fmt.Sprintf(`
<p>We received a request to reset your password. Click the link below:</p>
<p><a href="%s">Reset password</a></p>
<p>This link expires in 1 hour. If you didn't request a reset, ignore this email.</p>
`, link),
	})
	return err
}
