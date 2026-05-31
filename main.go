package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	// ── Signaling hub (pure relay – unchanged) ────────────────────────────────
	hub := NewHub()

	// ── SFU (pion/webrtc) ─────────────────────────────────────────────────────
	sfu := NewSFU()

	mux := http.NewServeMux()

	// ── WebSocket: pure signaling relay (original, untouched) ─────────────────
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		serveWS(hub, w, r)
	})

	// ── WebSocket: SFU endpoint (new) ─────────────────────────────────────────
	// Browsers that want server-mediated forwarding connect here.
	mux.HandleFunc("/ws/sfu", sfu.ServeWS)

	// ── REST: ICE server config ────────────────────────────────────────────────
	// The frontend calls /api/ice-config at start-up to discover STUN/TURN URLs
	// without hard-coding an IP.  Override via ICE_SERVERS env var (JSON array).
	mux.HandleFunc("/api/ice-config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")

		type iceServer struct {
			URLs       []string `json:"urls"`
			Username   string   `json:"username,omitempty"`
			Credential string   `json:"credential,omitempty"`
		}

		// Default: Google STUN only.
		servers := []iceServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
		}

		// Override with ICE_SERVERS env var if set.
		// Expected format (JSON array):
		//   [{"urls":["turn:my-server:3478"],"username":"u","credential":"p"}]
		if raw := os.Getenv("ICE_SERVERS"); raw != "" {
			var custom []iceServer
			if err := json.Unmarshal([]byte(raw), &custom); err == nil {
				servers = custom
			} else {
				log.Printf("ICE_SERVERS parse error: %v", err)
			}
		}

		if err := json.NewEncoder(w).Encode(map[string]any{
			"iceServers": servers,
		}); err != nil {
			log.Printf("/api/ice-config encode: %v", err)
		}
	})

	// ── REST: list active rooms (signaling hub) ───────────────────────────────
	mux.HandleFunc("/api/rooms", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"rooms": hub.GetRooms(),
		}); err != nil {
			log.Printf("/api/rooms encode: %v", err)
		}
	})

	// ── REST: server health ───────────────────────────────────────────────────
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	// ── Static: test frontend ─────────────────────────────────────────────────
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, "index.html")
	})

	addr := ":8080"
	log.Printf("══════════════════════════════════════════════════")
	log.Printf("  WebRTC Signaling + SFU Server")
	log.Printf("  Frontend     → http://localhost%s", addr)
	log.Printf("  WS relay     → ws://localhost%s/ws      (pure signaling)", addr)
	log.Printf("  WS SFU       → ws://localhost%s/ws/sfu  (pion/webrtc SFU)", addr)
	log.Printf("  Rooms API    → http://localhost%s/api/rooms", addr)
	log.Printf("  ICE config   → http://localhost%s/api/ice-config", addr)
	log.Printf("  TURN env var → ICE_SERVERS (JSON array of ICE server objects)")
	log.Printf("══════════════════════════════════════════════════")
	log.Fatal(http.ListenAndServe(addr, mux))
}