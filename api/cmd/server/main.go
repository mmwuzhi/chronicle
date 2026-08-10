package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	chiMW "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/ai"
	archiveapi "github.com/sikaoshenmi/chronicle/internal/archive"
	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/config"
	"github.com/sikaoshenmi/chronicle/internal/importer"
	"github.com/sikaoshenmi/chronicle/internal/linkfetch"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/objectstore"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
	"github.com/sikaoshenmi/chronicle/internal/search"
	"github.com/sikaoshenmi/chronicle/internal/upload"
	"github.com/sikaoshenmi/chronicle/internal/user"
	"github.com/sikaoshenmi/chronicle/internal/webhook"
)

func main() {
	cfg := config.Load()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("failed to connect to database", "err", err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		slog.Error("database ping failed", "err", err)
		os.Exit(1)
	}
	slog.Info("database connected")

	var legacyRedis *redis.Client
	if cfg.LegacyRedisURL != "" {
		redisOptions, err := redis.ParseURL(cfg.LegacyRedisURL)
		if err != nil {
			slog.Error("invalid legacy Redis URL", "err", err)
			os.Exit(1)
		}
		legacyRedis = redis.NewClient(redisOptions)
		defer legacyRedis.Close()
		if err := legacyRedis.Ping(ctx).Err(); err != nil {
			slog.Error("legacy auth-state Redis unavailable", "err", err)
			os.Exit(1)
		}
		slog.Info("legacy auth-state bridge enabled")
	}

	r := chi.NewRouter()
	r.Use(chiMW.Recoverer)
	allowedOrigins := []string{"http://localhost:5173"}
	if cfg.FrontendURL != "" {
		allowedOrigins = append(allowedOrigins, cfg.FrontendURL)
	}
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins: allowedOrigins,
		AllowedMethods: []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders: []string{
			"Authorization", "Content-Type", "Idempotency-Key",
			"X-Import-Filename", "X-Import-Time-Zone",
		},
		AllowCredentials: true,
	}))
	r.Use(middleware.TraceID)
	r.Use(middleware.Logger(logger))
	r.Use(middleware.RateLimit(200, time.Minute, middleware.IPKey))

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	api := humachi.New(r, huma.DefaultConfig("Chronicle API", "0.1.0"))
	api.UseMiddleware(auth.InjectHumaContext)

	auth.Register(api, r, pool, auth.Options{
		JWTSecret:          cfg.JWTSecret,
		ResendAPIKey:       cfg.ResendAPIKey,
		FrontendURL:        cfg.FrontendURL,
		APIBaseURL:         cfg.APIBaseURL,
		GoogleClientID:     cfg.GoogleClientID,
		GoogleClientSecret: cfg.GoogleClientSecret,
		GitHubClientID:     cfg.GitHubClientID,
		GitHubClientSecret: cfg.GitHubClientSecret,
		TurnstileSecret:    cfg.TurnstileSecret,
		WebAuthnRPID:       cfg.WebAuthnRPID,
		WebAuthnRPOrigin:   cfg.WebAuthnRPOrigin,
		LegacyRedis:        legacyRedis,
	})

	storageSettings, storageEnabled, err := cfg.ResolveObjectStorage()
	if err != nil {
		slog.Error("invalid object storage config", "err", err)
		os.Exit(1)
	}
	var s3client objectstore.Client
	if storageEnabled {
		s3client, err = objectstore.New(ctx, storageSettings)
		if err != nil {
			slog.Error("failed to configure object storage", "err", err)
			os.Exit(1)
		}
		slog.Info("object storage configured", "provider", storageSettings.Provider)
	}

	rag := ragclient.New(cfg.RAGServiceURL)
	if rag.Enabled() {
		slog.Info("RAG sidecar configured", "url", cfg.RAGServiceURL)
	}

	authMW := middleware.RequireAuthHuma(auth.ValidateToken(cfg.JWTSecret))
	// captureCreateMW additionally accepts long-lived capture tokens; it guards
	// only POST /captures (see capture.Register), keeping such tokens create-only.
	captureCreateMW := middleware.RequireAuthHumaCtx(auth.ValidateTokenOrPAT(cfg.JWTSecret, db.New(pool)))
	uploadConfig := upload.Config{
		BucketName:        storageSettings.Bucket,
		PublicBaseURL:     storageSettings.PublicBaseURL,
		OpenAIKey:         cfg.OpenAIKey,
		OpenAIBaseURL:     cfg.OpenAIBaseURL,
		OpenAIModel:       cfg.OpenAITranscriptionModel,
		OpenAIVisionModel: cfg.OpenAIVisionModel,
		VisionEnabled:     cfg.VisionEnabled,
	}
	kickTranscription := upload.StartTranscriptionWorker(ctx, pool, s3client, uploadConfig, rag)
	kickLinkFetch := linkfetch.StartLinkFetchWorker(ctx, pool, cfg.LinkFetchEnabled, rag)
	kickMediaDeletion := capture.StartMediaDeletionWorker(ctx, pool, s3client, storageSettings.Bucket)
	if cfg.LinkFetchEnabled {
		slog.Info("link enrichment enabled")
	}
	upload.Register(r, pool, s3client, uploadConfig, auth.ValidateToken(cfg.JWTSecret), kickTranscription)
	capture.Register(api, pool, rag, cfg.FrontendURL, authMW, captureCreateMW, kickTranscription, cfg.LinkFetchEnabled, kickLinkFetch, kickMediaDeletion)
	user.Register(api, pool, authMW, kickMediaDeletion)
	ai.Register(api, cfg.GeminiKey, authMW)
	search.Register(api, pool, rag, authMW)
	// Always register the webhook CRUD so the API contract (and the generated web
	// client / Integrations settings that always call /webhooks) stays stable
	// regardless of deployment. Rules are only *matched and delivered* by the RAG
	// sidecar; without it a rule is stored but never fires, which the UI surfaces
	// rather than 404-ing on a route that vanished with the env.
	webhook.Register(api, pool, rag, authMW)
	archiveapi.Register(
		api,
		r,
		pool,
		s3client,
		archiveapi.Config{
			BucketName:    storageSettings.Bucket,
			PublicBaseURL: storageSettings.PublicBaseURL,
			MaxBytes:      cfg.ArchiveMaxBytes,
		},
		rag,
		authMW,
		auth.ValidateToken(cfg.JWTSecret),
	)
	importer.Register(
		api,
		r,
		pool,
		importer.Config{MaxBytes: cfg.ArchiveMaxBytes},
		rag,
		authMW,
		auth.ValidateToken(cfg.JWTSecret),
	)

	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		slog.Info("server starting", "port", cfg.Port, "env", cfg.Env)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "err", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	slog.Info("shutting down")
	cancel()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "err", err)
	}
}
