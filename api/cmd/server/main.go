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

	"github.com/sikaoshenmi/chronicle/internal/ai"
	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/config"
	"github.com/sikaoshenmi/chronicle/internal/logentry"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/project"
	"github.com/sikaoshenmi/chronicle/internal/task"
	"github.com/sikaoshenmi/chronicle/internal/timeblock"
	"github.com/sikaoshenmi/chronicle/internal/user"
)

func main() {
	cfg := config.Load()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	ctx := context.Background()

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

	redisOpt, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		slog.Error("invalid redis URL", "err", err)
		os.Exit(1)
	}
	rdb := redis.NewClient(redisOpt)
	if err := rdb.Ping(ctx).Err(); err != nil {
		slog.Error("redis ping failed", "err", err)
		os.Exit(1)
	}
	slog.Info("redis connected")

	r := chi.NewRouter()
	r.Use(chiMW.Recoverer)
	allowedOrigins := []string{"http://localhost:5173"}
	if cfg.FrontendURL != "" {
		allowedOrigins = append(allowedOrigins, cfg.FrontendURL)
	}
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   allowedOrigins,
		AllowedMethods:   []string{"GET", "POST", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Authorization", "Content-Type"},
		AllowCredentials: true,
	}))
	r.Use(middleware.TraceID)
	r.Use(middleware.Logger(logger))
	r.Use(middleware.RateLimit(rdb, 200, time.Minute, middleware.IPKey))

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	api := humachi.New(r, huma.DefaultConfig("Chronicle API", "0.1.0"))
	api.UseMiddleware(auth.InjectHumaContext)

	auth.Register(api, r, pool, rdb, auth.Options{
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
	})

	authMW := middleware.RequireAuthHuma(auth.ValidateToken(cfg.JWTSecret))
	project.Register(api, pool, authMW)
	task.Register(api, pool, authMW)
	logentry.Register(api, pool, authMW)
	timeblock.Register(api, pool, authMW)
	capture.Register(api, pool, authMW)
	user.Register(api, pool, authMW)
	ai.Register(api, cfg.GeminiKey, authMW)

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
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "err", err)
	}
}
