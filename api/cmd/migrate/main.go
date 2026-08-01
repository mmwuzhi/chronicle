package main

import (
	"context"
	"database/sql"
	"log"
	"os"

	"github.com/pressly/goose/v3"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func main() {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is required")
	}
	database, err := sql.Open("pgx", databaseURL)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer database.Close()
	if err := goose.SetDialect("postgres"); err != nil {
		log.Fatalf("set migration dialect: %v", err)
	}
	if err := goose.UpContext(context.Background(), database, "db/migrations"); err != nil {
		log.Fatalf("apply migrations: %v", err)
	}
}
