// Package retrieval owns portable exact-query identity shared by search
// feedback and archive restore.
package retrieval

import (
	"crypto/sha256"
	"strings"

	"github.com/google/uuid"
	"golang.org/x/text/unicode/norm"
)

const (
	MaxSearchDismissalsPerUser = 1000
	MaxSearchQueryRunes        = 200
)

func NormalizeQuery(query string) string {
	return strings.Join(strings.Fields(strings.ToLower(norm.NFKC.String(query))), " ")
}

func QueryHash(userID uuid.UUID, query string) []byte {
	normalized := NormalizeQuery(query)
	data := make([]byte, 0, len(userID)+1+len(normalized))
	data = append(data, userID[:]...)
	data = append(data, 0)
	data = append(data, normalized...)
	digest := sha256.Sum256(data)
	return digest[:]
}
