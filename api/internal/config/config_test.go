package config

import "testing"

func TestValidateRejectsDisabledArchiveLimit(t *testing.T) {
	for _, value := range []int64{0, -1} {
		if err := validate(&Config{ArchiveMaxBytes: value}); err == nil {
			t.Fatalf("ArchiveMaxBytes %d was accepted", value)
		}
	}
	if err := validate(&Config{ArchiveMaxBytes: 1}); err != nil {
		t.Fatalf("positive ArchiveMaxBytes rejected: %v", err)
	}
}
