package main

import "encoding/json"

// ── Signaling message type constants ─────────────────────────────────────────

// Server → Client
const (
	TypePeerID     = "peer-id"     // Your assigned peer ID
	TypePeersList  = "peers-list"  // Occupants already in the room
	TypePeerJoined = "peer-joined" // A new participant entered
	TypePeerLeft   = "peer-left"   // A participant exited
	TypeError      = "error"       // Server-side error
)

// Client → Server
const (
	TypeJoin  = "join"  // Join (or create) a named room
	TypeLeave = "leave" // Leave current room
)

// Both directions – relayed peer-to-peer
const (
	TypeOffer  = "offer"
	TypeAnswer = "answer"
	TypeICE    = "ice-candidate"
)

// Message is the universal WebSocket signaling envelope.
//
//	type       — one of the constants above (required)
//	from       — sender peer-ID; set by the server on every inbound message
//	to         — target peer-ID; required for offer / answer / ice-candidate
//	room       — room name; echoed on room-scoped server messages
//	payload    — message-specific JSON body
type Message struct {
	Type    string          `json:"type"`
	From    string          `json:"from,omitempty"`
	To      string          `json:"to,omitempty"`
	Room    string          `json:"room,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
}