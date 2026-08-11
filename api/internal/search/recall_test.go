package search

import (
	"strings"
	"testing"
)

func TestValidatedSearchQueryKeepsCompatibilityExpansionAddressable(t *testing.T) {
	query := strings.Repeat("ﬃ", 200)
	if got, err := validatedSearchQuery(query); err != nil || got != query {
		t.Fatalf("compatibility-expanded query = %q, err = %v", got, err)
	}
	if _, err := validatedSearchQuery(strings.Repeat("a", 201)); err == nil {
		t.Fatal("expected raw query beyond the public limit to be rejected")
	}
}
