package migrations_test

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

const defaultTestDSN = "postgres://chronicle:chronicle@localhost:5432/chronicle_test?sslmode=disable"

// TestCaptureFirstUpgradeFromProductionBaseline exercises the exact release
// boundary: production is on migration 13, while capture-first adds 14–31.
// It pins both data conversion and the expand-only compatibility promise.
func TestCaptureFirstUpgradeFromProductionBaseline(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		dsn = defaultTestDSN
	}
	baseConfig, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatalf("parse test database URL: %v", err)
	}
	databaseName := fmt.Sprintf("chronicle_migration_%d", time.Now().UnixNano())
	adminConfig := baseConfig.Copy()
	adminConfig.Database = "postgres"
	adminDB := stdlib.OpenDB(*adminConfig)
	defer adminDB.Close()

	quotedName := `"` + databaseName + `"`
	if _, err := adminDB.ExecContext(context.Background(), "CREATE DATABASE "+quotedName); err != nil {
		t.Fatalf("create isolated migration database: %v", err)
	}
	t.Cleanup(func() {
		_, _ = adminDB.ExecContext(
			context.Background(),
			"DROP DATABASE IF EXISTS "+quotedName+" WITH (FORCE)",
		)
	})

	testConfig := baseConfig.Copy()
	testConfig.Database = databaseName
	db := stdlib.OpenDB(*testConfig)
	defer db.Close()
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("set goose dialect: %v", err)
	}
	if err := goose.UpTo(db, ".", 13); err != nil {
		t.Fatalf("migrate to production baseline: %v", err)
	}
	seedLegacyCaptureData(t, db)
	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("upgrade capture-first migrations: %v", err)
	}

	version, err := goose.GetDBVersion(db)
	if err != nil {
		t.Fatalf("read final migration version: %v", err)
	}
	if version != 31 {
		t.Fatalf("final migration version = %d, want 31", version)
	}

	for _, table := range []string{
		"projects", "tasks", "time_blocks", "log_entries",
		"weekly_reports", "public_shares",
	} {
		var exists bool
		if err := db.QueryRow(
			"SELECT to_regclass('public." + table + "') IS NOT NULL",
		).Scan(&exists); err != nil {
			t.Fatalf("check legacy table %s: %v", table, err)
		}
		if !exists {
			t.Fatalf("expand-only upgrade removed legacy table %s", table)
		}
	}
	var deletionOutboxExists bool
	if err := db.QueryRow(
		"SELECT to_regclass('public.capture_media_deletions') IS NOT NULL",
	).Scan(&deletionOutboxExists); err != nil {
		t.Fatalf("check media deletion outbox: %v", err)
	}
	if !deletionOutboxExists {
		t.Fatal("capture media deletion outbox was not created")
	}
	var archiveImportsExist bool
	if err := db.QueryRow(
		"SELECT to_regclass('public.archive_import_operations') IS NOT NULL",
	).Scan(&archiveImportsExist); err != nil {
		t.Fatalf("check archive import operations: %v", err)
	}
	if !archiveImportsExist {
		t.Fatal("archive import operations table was not created")
	}
	for _, table := range []string{"auth_ephemeral_states", "auth_rate_limits"} {
		var exists bool
		if err := db.QueryRow(
			"SELECT to_regclass('public." + table + "') IS NOT NULL",
		).Scan(&exists); err != nil {
			t.Fatalf("check PostgreSQL auth state table %s: %v", table, err)
		}
		if !exists {
			t.Fatalf("PostgreSQL auth state table %s was not created", table)
		}
	}
	for _, column := range []string{"task_id", "classified_as"} {
		var exists bool
		if err := db.QueryRow(`
			SELECT EXISTS (
			  SELECT 1 FROM information_schema.columns
			  WHERE table_schema = 'public' AND table_name = 'captures'
			    AND column_name = $1
			)`, column).Scan(&exists); err != nil {
			t.Fatalf("check compatibility column %s: %v", column, err)
		}
		if !exists {
			t.Fatalf("expand-only upgrade removed captures.%s", column)
		}
	}

	var taggedText string
	var todoPresent bool
	if err := db.QueryRow(`
		SELECT raw_text, todo_at IS NOT NULL
		FROM captures
		WHERE id = '30000000-0000-0000-0000-000000000001'
	`).Scan(&taggedText, &todoPresent); err != nil {
		t.Fatalf("read converted capture: %v", err)
	}
	if taggedText != "legacy action #todo" || !todoPresent {
		t.Fatalf("todo conversion = (%q, %v), want tagged actionable capture", taggedText, todoPresent)
	}

	var migratedTasks, archivedTasks, liveTasks int
	if err := db.QueryRow(
		"SELECT count(*) FROM captures WHERE source = 'migrated'",
	).Scan(&migratedTasks); err != nil {
		t.Fatalf("count migrated captures: %v", err)
	}
	if err := db.QueryRow("SELECT count(*) FROM archived_tasks").Scan(&archivedTasks); err != nil {
		t.Fatalf("count archived tasks: %v", err)
	}
	if err := db.QueryRow("SELECT count(*) FROM tasks").Scan(&liveTasks); err != nil {
		t.Fatalf("count retained tasks: %v", err)
	}
	if migratedTasks != 2 || archivedTasks != 1 || liveTasks != 1 {
		t.Fatalf(
			"unexpected conversion counts: migrated=%d archived=%d retained=%d",
			migratedTasks,
			archivedTasks,
			liveTasks,
		)
	}
}

func seedLegacyCaptureData(t *testing.T, db *sql.DB) {
	t.Helper()
	statements := []string{
		`INSERT INTO users (id, email, password_hash)
		 VALUES ('10000000-0000-0000-0000-000000000001', 'migration@example.com', 'hash')`,
		`INSERT INTO projects (id, user_id, name)
		 VALUES (
		  '20000000-0000-0000-0000-000000000001',
		  '10000000-0000-0000-0000-000000000001',
		  'Legacy project'
		 )`,
		`INSERT INTO tasks (id, user_id, project_id, title, type, status, start_at)
		 VALUES (
		  '20000000-0000-0000-0000-000000000002',
		  '10000000-0000-0000-0000-000000000001',
		  '20000000-0000-0000-0000-000000000001',
		  'Migrated task', 'task', 'todo', now()
		 )`,
		`INSERT INTO time_blocks (id, user_id, task_id, started_at, ended_at, duration_sec)
		 VALUES (
		  '20000000-0000-0000-0000-000000000003',
		  '10000000-0000-0000-0000-000000000001',
		  '20000000-0000-0000-0000-000000000002',
		  now() - interval '10 minutes', now(), 600
		 )`,
		`INSERT INTO log_entries (id, user_id, task_id, body)
		 VALUES (
		  '20000000-0000-0000-0000-000000000004',
		  '10000000-0000-0000-0000-000000000001',
		  '20000000-0000-0000-0000-000000000002',
		  'Migrated log'
		 )`,
		`INSERT INTO captures (
		   id, user_id, raw_text, media_type, classified_as, task_id, source
		 ) VALUES (
		  '30000000-0000-0000-0000-000000000001',
		  '10000000-0000-0000-0000-000000000001',
		  'legacy action', 'text', 'task',
		  '20000000-0000-0000-0000-000000000002',
		  'web'
		 )`,
		`INSERT INTO weekly_reports (id, user_id, week_start, data)
		 VALUES (
		  '40000000-0000-0000-0000-000000000001',
		  '10000000-0000-0000-0000-000000000001',
		  current_date, '{"kept":true}'
		 )`,
		`INSERT INTO public_shares (id, report_id, slug)
		 VALUES (
		  '40000000-0000-0000-0000-000000000002',
		  '40000000-0000-0000-0000-000000000001',
		  'migration-share'
		 )`,
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("seed production baseline: %v\n%s", err, statement)
		}
	}
}
