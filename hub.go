package main

import (
	"encoding/json"
	"log"
	"sync"
)

// Hub is the central state store: it owns every live Client and every Room.
// All mutations are serialised through a single read-write mutex so the data
// structures are safe to access from many goroutines simultaneously.
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*Client            // peerID  → client
	rooms   map[string]map[string]*Client // roomID  → { peerID → client }
}

// NewHub constructs an empty Hub.
func NewHub() *Hub {
	return &Hub{
		clients: make(map[string]*Client),
		rooms:   make(map[string]map[string]*Client),
	}
}

// ── Registration ─────────────────────────────────────────────────────────────

// Register adds a freshly-connected client.
func (h *Hub) Register(c *Client) {
	h.mu.Lock()
	h.clients[c.id] = c
	h.mu.Unlock()
	log.Printf("[+] client %-12s connected  (total=%d)", c.id, h.clientCount())
}

// Unregister removes a disconnected client and cleans up room membership.
// It is idempotent – safe to call more than once.
func (h *Hub) Unregister(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, exists := h.clients[c.id]; !exists {
		return // already removed
	}
	delete(h.clients, c.id)

	if c.room != "" {
		h.leaveRoomLocked(c)
	}
	c.closeSend() // signal writePump to stop

	log.Printf("[-] client %-12s disconnected (total=%d)", c.id, len(h.clients))
}

// ── Room management ──────────────────────────────────────────────────────────

// JoinRoom places client c into roomID, leaving any prior room first.
//
// Sequence:
//  1. leaveRoomLocked (if in another room)
//  2. Create room if it does not exist
//  3. Snapshot existing peers, then add c
//  4. Send TypePeersList → c
//  5. Broadcast TypePeerJoined → everyone else in the room
func (h *Hub) JoinRoom(c *Client, roomID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if c.room == roomID {
		return // already here
	}
	if c.room != "" {
		h.leaveRoomLocked(c)
	}

	if h.rooms[roomID] == nil {
		h.rooms[roomID] = make(map[string]*Client)
		log.Printf("[+] room %q created", roomID)
	}

	// Snapshot before adding so the joiner's own ID is not in the list.
	existing := make([]string, 0, len(h.rooms[roomID]))
	for pid := range h.rooms[roomID] {
		existing = append(existing, pid)
	}

	h.rooms[roomID][c.id] = c
	c.room = roomID
	log.Printf("[>] client %s joined room %q  (%d peer(s) already present)", c.id, roomID, len(existing))

	// Tell the joiner who is already here so it can initiate offers.
	safeSend(c.send, Message{
		Type:    TypePeersList,
		Room:    roomID,
		Payload: mustMarshal(map[string]any{"peers": existing}),
	})

	// Tell everyone else that a new peer has arrived.
	joinMsg := Message{Type: TypePeerJoined, From: c.id, Room: roomID}
	for pid, peer := range h.rooms[roomID] {
		if pid != c.id {
			safeSend(peer.send, joinMsg)
		}
	}
}

// LeaveRoom removes c from its current room.
func (h *Hub) LeaveRoom(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c.room != "" {
		h.leaveRoomLocked(c)
	}
}

// leaveRoomLocked performs the actual removal.  MUST be called with h.mu held.
func (h *Hub) leaveRoomLocked(c *Client) {
	room, ok := h.rooms[c.room]
	if !ok {
		c.room = ""
		return
	}
	roomID := c.room
	delete(room, c.id)
	c.room = ""

	if len(room) == 0 {
		delete(h.rooms, roomID)
		log.Printf("[-] room %q removed (empty)", roomID)
		return
	}

	// Notify the remaining occupants.
	gone := Message{Type: TypePeerLeft, From: c.id, Room: roomID}
	for _, peer := range room {
		safeSend(peer.send, gone)
	}
}

// ── Relay ────────────────────────────────────────────────────────────────────

// Relay forwards a peer-to-peer signaling message (offer/answer/ICE) to the
// intended recipient.  Only msg.To is used for routing; msg.From is already
// set by the caller.
func (h *Hub) Relay(msg Message) {
	h.mu.RLock()
	target, ok := h.clients[msg.To]
	h.mu.RUnlock()

	if !ok {
		log.Printf("[!] relay: unknown target %q (from=%s type=%s)", msg.To, msg.From, msg.Type)
		return
	}
	safeSend(target.send, msg)
}

// ── Stats / REST ─────────────────────────────────────────────────────────────

// GetRooms returns a snapshot map of roomID → participant count.
func (h *Hub) GetRooms() map[string]int {
	h.mu.RLock()
	defer h.mu.RUnlock()

	out := make(map[string]int, len(h.rooms))
	for id, members := range h.rooms {
		out[id] = len(members)
	}
	return out
}

func (h *Hub) clientCount() int {
	// Assumes caller does NOT hold the lock (takes RLock itself).
	h.mu.RLock()
	n := len(h.clients)
	h.mu.RUnlock()
	return n
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// safeSend delivers msg to ch without blocking.
// It recovers silently from sends on a closed channel.
func safeSend(ch chan Message, msg Message) {
	defer func() { recover() }()
	select {
	case ch <- msg:
	default:
		// Receiver is not keeping up – drop the message rather than block.
	}
}

// mustMarshal marshals v to JSON; returns an empty object on error.
func mustMarshal(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage("{}")
	}
	return b
}