package main

import (
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ── Timing constants ──────────────────────────────────────────────────────────

const (
	writeWait      = 10 * time.Second       // Maximum time allowed to write a message
	pongWait       = 60 * time.Second       // Time the client has to send a pong
	pingPeriod     = pongWait * 9 / 10      // Ping interval (must be < pongWait)
	maxMessageSize = 65_536                 // 64 KB – comfortably holds any SDP blob
)

// ── WebSocket upgrader ────────────────────────────────────────────────────────

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// Allow all origins for local testing.
	// Restrict this in production: compare r.Header.Get("Origin") against an allowlist.
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ── Client ────────────────────────────────────────────────────────────────────

// Client represents one connected WebSocket peer.
type Client struct {
	id        string          // Unique peer ID assigned on connect
	room      string          // Current room name; "" = not in any room
	conn      *websocket.Conn // Underlying WebSocket connection
	send      chan Message     // Outbound message queue (writePump drains this)
	hub       *Hub
	closeOnce sync.Once // Ensures send is closed exactly once
}

// closeSend closes the outbound channel exactly once, which signals writePump
// to send a WebSocket close frame and exit.
func (c *Client) closeSend() {
	c.closeOnce.Do(func() { close(c.send) })
}

func newClient(h *Hub, conn *websocket.Conn) *Client {
	return &Client{
		id:   randomID(),
		conn: conn,
		send: make(chan Message, 512),
		hub:  h,
	}
}

// randomID generates a 12-character lowercase alphanumeric peer ID.
func randomID() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	b := make([]byte, 12)
	for i := range b {
		b[i] = alphabet[r.Intn(len(alphabet))]
	}
	return string(b)
}

// ── HTTP handler ──────────────────────────────────────────────────────────────

// serveWS upgrades an HTTP request to WebSocket, registers the client, and
// spawns its read and write goroutines.
func serveWS(h *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade: %v", err)
		return
	}

	c := newClient(h, conn)
	h.Register(c)

	// Immediately tell the client its assigned peer ID.
	safeSend(c.send, Message{
		Type:    TypePeerID,
		Payload: mustMarshal(map[string]string{"id": c.id}),
	})

	go c.writePump()
	go c.readPump()
}

// ── Read pump ─────────────────────────────────────────────────────────────────

// readPump reads inbound messages from the WebSocket and dispatches them.
// Each client has exactly one readPump goroutine.
// When readPump returns (connection closed / error), it unregisters the client.
func (c *Client) readPump() {
	defer func() {
		c.hub.Unregister(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		var msg Message
		if err := c.conn.ReadJSON(&msg); err != nil {
			if websocket.IsUnexpectedCloseError(err,
				websocket.CloseGoingAway,
				websocket.CloseAbnormalClosure,
			) {
				log.Printf("client %s read error: %v", c.id, err)
			}
			return
		}
		// Always override the From field so clients cannot spoof each other.
		msg.From = c.id
		c.dispatch(msg)
	}
}

// ── Write pump ────────────────────────────────────────────────────────────────

// writePump drains c.send and writes each message to the WebSocket.
// It also sends periodic pings to keep the connection alive.
// Each client has exactly one writePump goroutine.
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case msg, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// Hub closed the channel → send a clean close frame.
				c.conn.WriteMessage(websocket.CloseMessage, nil)
				return
			}
			if err := c.conn.WriteJSON(msg); err != nil {
				log.Printf("client %s write error: %v", c.id, err)
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// ── Message dispatch ──────────────────────────────────────────────────────────

// dispatch routes an inbound message to the appropriate handler.
func (c *Client) dispatch(msg Message) {
	switch msg.Type {

	// ── Join room ──────────────────────────────────────────────────────────
	case TypeJoin:
		var p struct {
			Room string `json:"room"`
		}
		if err := json.Unmarshal(msg.Payload, &p); err != nil || p.Room == "" {
			c.sendError("join: payload must contain a non-empty \"room\" field")
			return
		}
		c.hub.JoinRoom(c, p.Room)

	// ── Leave room ─────────────────────────────────────────────────────────
	case TypeLeave:
		c.hub.LeaveRoom(c)

	// ── Peer-to-peer relay (offer / answer / ICE candidate) ────────────────
	case TypeOffer, TypeAnswer, TypeICE:
		if msg.To == "" {
			c.sendError("relay message must include a non-empty \"to\" field")
			return
		}
		c.hub.Relay(msg)

	default:
		log.Printf("client %s: unknown message type %q", c.id, msg.Type)
	}
}

func (c *Client) sendError(text string) {
	safeSend(c.send, Message{
		Type:    TypeError,
		Payload: mustMarshal(map[string]string{"message": text}),
	})
}