package testutil

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

const defaultDSN = "postgres://chronicle:chronicle@localhost:5432/chronicle_test?sslmode=disable"

// migrationsDir resolves the db/migrations directory relative to this file,
// so tests can be run from any working directory.
func migrationsDir() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "db", "migrations")
}

// NewPool connects to the test database, runs all pending migrations, and
// returns a pool. It registers a cleanup that closes the pool when the test ends.
// Set TEST_DATABASE_URL to override the default connection string.
func NewPool(t *testing.T) *pgxpool.Pool {
	t.Helper()

	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		dsn = defaultDSN
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("testutil: connect to test DB: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("testutil: ping test DB: %v — is postgres running? (docker compose up -d postgres)", err)
	}

	// Run migrations via goose using the pgx stdlib adapter.
	sqlDB := stdlib.OpenDBFromPool(pool)
	runMigrations(t, sqlDB)

	t.Cleanup(func() {
		sqlDB.Close()
		pool.Close()
	})

	return pool
}

func runMigrations(t *testing.T, db *sql.DB) {
	t.Helper()
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("testutil: goose set dialect: %v", err)
	}
	if err := goose.Up(db, migrationsDir()); err != nil {
		t.Fatalf("testutil: goose up: %v", err)
	}
}

// Truncate deletes all rows from the given tables in a single statement.
// Call this at the start of each test that writes to the DB.
func Truncate(t *testing.T, pool *pgxpool.Pool, tables ...string) {
	t.Helper()
	for _, table := range tables {
		if _, err := pool.Exec(context.Background(), "TRUNCATE TABLE "+table+" CASCADE"); err != nil {
			t.Fatalf("testutil: truncate %s: %v", table, err)
		}
	}
}
