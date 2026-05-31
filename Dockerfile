# ── Build stage ───────────────────────────────────────────────────────────────
FROM golang:1.24-alpine AS builder

WORKDIR /app

# git is required by go mod download for some pion sub-modules
RUN apk add --no-cache git

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server .

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM alpine:latest

RUN adduser -D appuser

WORKDIR /app

COPY --from=builder /app/server .
COPY --from=builder /app/index.html .

RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8080

# ICE_SERVERS: JSON array of ICE server objects.
# Example (TURN):
#   [{"urls":["turn:1.2.3.4:3478"],"username":"u","credential":"p"}]
ENV ICE_SERVERS=""

CMD ["./server"]