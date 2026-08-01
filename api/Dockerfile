FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o chronicle ./cmd/server
RUN go build -o migrate ./cmd/migrate

FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata wget
WORKDIR /app
COPY --from=builder /app/chronicle .
COPY --from=builder /app/migrate .
COPY --from=builder /app/db/migrations ./db/migrations
EXPOSE 8080
CMD ["./chronicle"]
