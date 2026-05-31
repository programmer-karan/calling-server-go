package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/livekit/protocol/auth"
)

func main() {
	apiKey := getEnv("LIVEKIT_API_KEY", "devkey")
	apiSecret := getEnv("LIVEKIT_API_SECRET", "devsecret")

	mux := http.NewServeMux()

	// ── Token endpoint ──────────────────────────────────────────────────────
	// GET /api/token?room=ROOM&identity=NAME
	// Returns a JWT token that the Flutter/web client uses to join a room.
	mux.HandleFunc("/api/token", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == "OPTIONS" {
			return
		}

		room := r.URL.Query().Get("room")
		identity := r.URL.Query().Get("identity")
		if room == "" || identity == "" {
			http.Error(w, `{"error":"room and identity query params required"}`, 400)
			return
		}

		// Create token with full permissions.
		at := auth.NewAccessToken(apiKey, apiSecret)
		grant := &auth.VideoGrant{
			RoomJoin: true,
			Room:     room,
		}
		at.AddGrant(grant).
			SetIdentity(identity).
			SetValidFor(24 * time.Hour)

		token, err := at.ToJWT()
		if err != nil {
			http.Error(w, `{"error":"token generation failed"}`, 500)
			log.Printf("Token error: %v", err)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"token": token,
			"url":   getEnv("LIVEKIT_URL", "ws://localhost:7880"),
		})
		log.Printf("Token issued: room=%s identity=%s", room, identity)
	})

	// ── Health ───────────────────────────────────────────────────────────────
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"ok"}`))
	})

	addr := ":8080"
	log.Printf("Token server → http://localhost%s/api/token?room=ROOM&identity=NAME", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
