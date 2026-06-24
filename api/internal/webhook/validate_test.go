package webhook

import (
	"reflect"
	"testing"
)

func TestNormalizeKeywords(t *testing.T) {
	cases := []struct {
		name string
		in   []string
		want []string
	}{
		// An empty keyword must never survive: the sidecar match is
		// `any(k in content for k in keywords)`, and `"" in s` is always true in
		// Python, so it would fire the webhook on every capture.
		{"drops empty and whitespace", []string{"foo", "", "  ", " bar "}, []string{"foo", "bar"}},
		{"nil becomes empty slice", nil, []string{}},
		{"all empty becomes empty slice", []string{"", "   "}, []string{}},
		{"keeps order and trims", []string{" a ", "b"}, []string{"a", "b"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := normalizeKeywords(c.in)
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("normalizeKeywords(%#v) = %#v, want %#v", c.in, got, c.want)
			}
		})
	}
}

func TestValidateWebhookURL(t *testing.T) {
	valid := []string{
		"https://example.com/hook",
		"http://hooks.example.com:8080/path",
		"https://sub.domain.example.org/webhooks/abc",
	}
	for _, u := range valid {
		if err := validateWebhookURL(u); err != nil {
			t.Errorf("expected %q to be valid, got %v", u, err)
		}
	}

	invalid := []string{
		"",
		"ftp://example.com",
		"file:///etc/passwd",
		"http://localhost/x",
		"https://api.localhost/x",
		"https://127.0.0.1/x",
		"http://10.0.0.5/x",
		"http://192.168.1.1/x",
		"http://169.254.169.254/latest/meta-data", // cloud metadata
		"https://[::1]/x",
	}
	for _, u := range invalid {
		if err := validateWebhookURL(u); err == nil {
			t.Errorf("expected %q to be rejected", u)
		}
	}
}
