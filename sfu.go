package main

// sfu.go — Selective Forwarding Unit built on pion/webrtc.
//
// Architecture
// ────────────────────────────────────────────────────────────
//  Browser A ──WS/SFU──► sfuPeer (publisher)
//                              │  RTP track A
//                              ▼
//                         sfuRoom.tracks["A-video"]
//                         sfuRoom.tracks["A-audio"]
//                              │
//                              ▼ (fan-out via TrackLocalStaticRTP)
//  Browser B ◄──WS/SFU──  sfuPeer (subscriber)
//  Browser C ◄──WS/SFU──  sfuPeer (subscriber)
//
// Each peer has one PeerConnection that simultaneously:
//   • Sends its own tracks to the SFU (publisher role)
//   • Receives all other peers' tracks from the SFU (subscriber role)
//
// Signaling flow (over the /ws/sfu WebSocket):
//   Client → {"type":"sfu-join",  "payload":{"room":"…"}}
//   Server → {"type":"sfu-offer", "payload":{"sdp":"…"}}       (or vice-versa)
//   Client → {"type":"sfu-answer","payload":{"sdp":"…"}}
//   Either → {"type":"sfu-ice",   "payload":{"candidate":{…}}}
//   Server → {"type":"sfu-offer", "payload":{"sdp":"…"}}       re-negotiation
//             when a new publisher track is available

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v3"
)

// ── SFU-specific message type constants ──────────────────────────────────────

const (
	TypeSFUJoin      = "sfu-join"
	TypeSFUOffer     = "sfu-offer"
	TypeSFUAnswer    = "sfu-answer"
	TypeSFUIce       = "sfu-ice"
	TypeSFUPeerJoined = "sfu-peer-joined"
	TypeSFUPeerLeft  = "sfu-peer-left"
)

// ── ICE / WebRTC config ───────────────────────────────────────────────────────

// DefaultWebRTCConfig is the pion WebRTC API configuration.
// Operators can extend ICEServers via environment or a config file;
// for now we use Google STUN + a Coturn TURN placeholder.
var DefaultWebRTCConfig = webrtc.Configuration{
	ICEServers: []webrtc.ICEServer{
		{URLs: []string{"stun:stun.l.google.com:19302"}},
		// Uncomment and fill in when you have a TURN server:
		// {
		//     URLs:       []string{"turn:your-turn-server:3478"},
		//     Username:   "webrtcuser",
		//     Credential: "webrtcpass",
		// },
	},
}

// ── sfuRoom ───────────────────────────────────────────────────────────────────

// sfuRoom holds all peers and published tracks for one room.
type sfuRoom struct {
	mu     sync.RWMutex
	id     string
	peers  map[string]*sfuPeer                    // peerID → peer
	tracks map[string]*webrtc.TrackLocalStaticRTP // trackID → local track
}

func newSFURoom(id string) *sfuRoom {
	return &sfuRoom{
		id:     id,
		peers:  make(map[string]*sfuPeer),
		tracks: make(map[string]*webrtc.TrackLocalStaticRTP),
	}
}

// addTrack stores a forwarder track and triggers re-negotiation for all
// existing subscribers so they receive the new track.
func (r *sfuRoom) addTrack(t *webrtc.TrackLocalStaticRTP) {
	r.mu.Lock()
	r.tracks[t.ID()] = t
	peers := make([]*sfuPeer, 0, len(r.peers))
	for _, p := range r.peers {
		peers = append(peers, p)
	}
	r.mu.Unlock()

	log.Printf("[SFU] room %q: new track %s – triggering renegotiation for %d peer(s)",
		r.id, t.ID(), len(peers))

	for _, p := range peers {
		go p.renegotiate()
	}
}

// removeTrack deletes a forwarding track (called when its publisher disconnects).
func (r *sfuRoom) removeTrack(trackID string) {
	r.mu.Lock()
	delete(r.tracks, trackID)
	r.mu.Unlock()
}

// snapshot returns a point-in-time slice of all current tracks.
func (r *sfuRoom) snapshot() []*webrtc.TrackLocalStaticRTP {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]*webrtc.TrackLocalStaticRTP, 0, len(r.tracks))
	for _, t := range r.tracks {
		out = append(out, t)
	}
	return out
}

// ── SFU (top-level) ───────────────────────────────────────────────────────────

// SFU owns all sfuRooms and provides the HTTP handler for /ws/sfu.
type SFU struct {
	mu    sync.RWMutex
	rooms map[string]*sfuRoom
	api   *webrtc.API
}

// NewSFU creates an SFU with a pion MediaEngine pre-configured for common codecs.
func NewSFU() *SFU {
	me := &webrtc.MediaEngine{}
	if err := me.RegisterDefaultCodecs(); err != nil {
		log.Fatalf("SFU: RegisterDefaultCodecs: %v", err)
	}

	i := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(me, i); err != nil {
		log.Fatalf("SFU: RegisterDefaultInterceptors: %v", err)
	}

	return &SFU{
		rooms: make(map[string]*sfuRoom),
		api:   webrtc.NewAPI(webrtc.WithMediaEngine(me), webrtc.WithInterceptorRegistry(i)),
	}
}

// getOrCreateRoom is concurrency-safe room lookup/creation.
func (s *SFU) getOrCreateRoom(id string) *sfuRoom {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.rooms[id]; ok {
		return r
	}
	r := newSFURoom(id)
	s.rooms[id] = r
	log.Printf("[SFU] room %q created", id)
	return r
}

// deleteRoomIfEmpty removes the room when the last peer leaves.
func (s *SFU) deleteRoomIfEmpty(roomID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.rooms[roomID]; ok {
		r.mu.RLock()
		empty := len(r.peers) == 0
		r.mu.RUnlock()
		if empty {
			delete(s.rooms, roomID)
			log.Printf("[SFU] room %q removed (empty)", roomID)
		}
	}
}

// ServeWS is the HTTP handler for GET /ws/sfu.
func (s *SFU) ServeWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[SFU] ws upgrade: %v", err)
		return
	}

	p := newSFUPeer(s, conn)
	log.Printf("[SFU] peer %s connected", p.id)

	go p.readLoop()
}

// ── sfuPeer ───────────────────────────────────────────────────────────────────

// sfuPeer represents one browser endpoint connected to the SFU.
type sfuPeer struct {
	id   string
	sfu  *SFU
	room *sfuRoom

	conn     *websocket.Conn
	writeMu  sync.Mutex // serialize WebSocket writes

	pc       *webrtc.PeerConnection
	pcMu     sync.Mutex // protects pc lifecycle

	// trackIDs published by this peer (for cleanup on disconnect)
	publishedTracks []string
	pubMu           sync.Mutex

	// negotiation channel – serializes renegotiation requests
	negCh    chan struct{}
	done     chan struct{}
}

func newSFUPeer(s *SFU, conn *websocket.Conn) *sfuPeer {
	p := &sfuPeer{
		id:   randomID(),
		sfu:  s,
		conn: conn,
		negCh: make(chan struct{}, 1),
		done:  make(chan struct{}),
	}
	go p.pingLoop()
	go p.negotiationLoop()
	return p
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

func (p *sfuPeer) close() {
	// Signal loops to stop.
	select {
	case <-p.done:
	default:
		close(p.done)
	}

	// Remove from room.
	if p.room != nil {
		p.room.mu.Lock()
		delete(p.room.peers, p.id)
		p.room.mu.Unlock()

		// Clean up tracks this peer was publishing.
		p.pubMu.Lock()
		for _, tid := range p.publishedTracks {
			p.room.removeTrack(tid)
		}
		p.pubMu.Unlock()

		// Notify remaining peers.
		p.room.mu.RLock()
		for _, peer := range p.room.peers {
			peer.sendJSON(Message{Type: TypeSFUPeerLeft, From: p.id})
		}
		p.room.mu.RUnlock()

		p.sfu.deleteRoomIfEmpty(p.room.id)
	}

	p.pcMu.Lock()
	if p.pc != nil {
		p.pc.Close()
	}
	p.pcMu.Unlock()

	p.conn.Close()
	log.Printf("[SFU] peer %s disconnected", p.id)
}

// pingLoop sends periodic WebSocket pings to keep the connection alive.
func (p *sfuPeer) pingLoop() {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-p.done:
			return
		case <-ticker.C:
			p.writeMu.Lock()
			p.conn.SetWriteDeadline(time.Now().Add(writeWait))
			err := p.conn.WriteMessage(websocket.PingMessage, nil)
			p.writeMu.Unlock()
			if err != nil {
				return
			}
		}
	}
}

// negotiationLoop serializes renegotiation so concurrent track additions
// don't produce overlapping offer/answer exchanges.
func (p *sfuPeer) negotiationLoop() {
	for {
		select {
		case <-p.done:
			return
		case <-p.negCh:
			p.doRenegotiate()
		}
	}
}

// ── WebSocket I/O ─────────────────────────────────────────────────────────────

func (p *sfuPeer) sendJSON(m Message) {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := p.conn.WriteJSON(m); err != nil {
		log.Printf("[SFU] peer %s write err: %v", p.id, err)
	}
}

func (p *sfuPeer) readLoop() {
	defer p.close()

	p.conn.SetReadLimit(maxMessageSize)
	p.conn.SetReadDeadline(time.Now().Add(pongWait))
	p.conn.SetPongHandler(func(string) error {
		p.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	// Send assigned peer ID immediately.
	p.sendJSON(Message{
		Type:    TypePeerID,
		Payload: mustMarshal(map[string]string{"id": p.id}),
	})

	for {
		var msg Message
		if err := p.conn.ReadJSON(&msg); err != nil {
			if websocket.IsUnexpectedCloseError(err,
				websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[SFU] peer %s read err: %v", p.id, err)
			}
			return
		}
		msg.From = p.id
		p.dispatch(msg)
	}
}

// ── Message dispatch ──────────────────────────────────────────────────────────

func (p *sfuPeer) dispatch(msg Message) {
	switch msg.Type {

	case TypeSFUJoin:
		var pay struct {
			Room string `json:"room"`
		}
		if err := json.Unmarshal(msg.Payload, &pay); err != nil || pay.Room == "" {
			p.sendJSON(Message{Type: TypeError,
				Payload: mustMarshal(map[string]string{"message": "sfu-join: missing room"})})
			return
		}
		p.joinRoom(pay.Room)

	case TypeSFUAnswer:
		var pay struct {
			SDP string `json:"sdp"`
		}
		if err := json.Unmarshal(msg.Payload, &pay); err != nil {
			return
		}
		p.handleAnswer(webrtc.SessionDescription{
			Type: webrtc.SDPTypeAnswer,
			SDP:  pay.SDP,
		})

	case TypeSFUIce:
		var pay struct {
			Candidate webrtc.ICECandidateInit `json:"candidate"`
		}
		if err := json.Unmarshal(msg.Payload, &pay); err != nil {
			return
		}
		p.handleICE(pay.Candidate)

	default:
		log.Printf("[SFU] peer %s: unknown type %q", p.id, msg.Type)
	}
}

// ── Room join ────────────────────────────────────────────────────────────────

func (p *sfuPeer) joinRoom(roomID string) {
	room := p.sfu.getOrCreateRoom(roomID)
	p.room = room

	// Build PeerConnection.
	if err := p.buildPC(); err != nil {
		log.Printf("[SFU] peer %s buildPC: %v", p.id, err)
		return
	}

	// Subscribe to all pre-existing tracks (skip our own).
	for _, t := range room.snapshot() {
		if t.StreamID() == p.id {
			continue // don't subscribe to our own tracks
		}
		p.addRemoteTrackToPC(t)
	}

	// Register this peer in the room.
	room.mu.Lock()
	room.peers[p.id] = p
	// Notify existing peers about the newcomer.
	for pid, peer := range room.peers {
		if pid != p.id {
			peer.sendJSON(Message{Type: TypeSFUPeerJoined, From: p.id})
		}
	}
	room.mu.Unlock()

	// Create initial offer so the browser knows to send its tracks.
	p.renegotiate()

	log.Printf("[SFU] peer %s joined room %q", p.id, roomID)
}

// ── PeerConnection builder ────────────────────────────────────────────────────

func (p *sfuPeer) buildPC() error {
	p.pcMu.Lock()
	defer p.pcMu.Unlock()

	pc, err := p.sfu.api.NewPeerConnection(DefaultWebRTCConfig)
	if err != nil {
		return err
	}
	p.pc = pc

	// Accept inbound audio and video from this browser.
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		return err
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		return err
	}

	// ── Track handler: when the browser sends us a track, forward it ──────────
	pc.OnTrack(func(remoteTrack *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		log.Printf("[SFU] peer %s publishing %s track (codec=%s)",
			p.id, remoteTrack.Kind(), remoteTrack.Codec().MimeType)

		// Create a local track to fan-out to subscribers.
		localTrack, err := webrtc.NewTrackLocalStaticRTP(
			remoteTrack.Codec().RTPCodecCapability,
			p.id+"-"+remoteTrack.Kind().String(),
			p.id,
		)
		if err != nil {
			log.Printf("[SFU] NewTrackLocalStaticRTP: %v", err)
			return
		}

		// Register locally and trigger renegotiation for subscribers.
		p.pubMu.Lock()
		p.publishedTracks = append(p.publishedTracks, localTrack.ID())
		p.pubMu.Unlock()
		p.room.addTrack(localTrack)

		// Send RTCP PLI requests periodically so keyframes keep arriving.
		go func() {
			ticker := time.NewTicker(3 * time.Second)
			defer ticker.Stop()
			for range ticker.C {
				if err := pc.WriteRTCP([]rtcp.Packet{
					&rtcp.PictureLossIndication{
						MediaSSRC: uint32(remoteTrack.SSRC()),
					},
				}); err != nil {
					return // PC closed
				}
			}
		}()

		// RTP forward loop: read from remote, write to local forwarder.
		buf := make([]byte, 1500)
		for {
			n, _, err := remoteTrack.Read(buf)
			if err != nil {
				log.Printf("[SFU] track %s read done: %v", localTrack.ID(), err)
				return
			}
			if _, err = localTrack.Write(buf[:n]); err != nil {
				log.Printf("[SFU] track %s write done: %v", localTrack.ID(), err)
				return
			}
		}
	})

	// ── ICE candidates → relay to browser ─────────────────────────────────────
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		p.sendJSON(Message{
			Type:    TypeSFUIce,
			Payload: mustMarshal(map[string]any{"candidate": c.ToJSON()}),
		})
	})

	// ── Connection state logging ───────────────────────────────────────────────
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		log.Printf("[SFU] peer %s state → %s", p.id, st)
		if st == webrtc.PeerConnectionStateFailed {
			pc.Close()
		}
	})

	return nil
}

// ── Track subscription ────────────────────────────────────────────────────────

// addRemoteTrackToPC adds a room-level forwarding track as an outbound sender
// on this peer's PeerConnection.  Must be called before renegotiate().
func (p *sfuPeer) addRemoteTrackToPC(t *webrtc.TrackLocalStaticRTP) {
	if t.StreamID() == p.id {
		return // don't subscribe to our own tracks
	}
	p.pcMu.Lock()
	defer p.pcMu.Unlock()
	if p.pc == nil {
		return
	}
	if _, err := p.pc.AddTrack(t); err != nil {
		log.Printf("[SFU] peer %s AddTrack %s: %v", p.id, t.ID(), err)
	}
}

// ── Offer/answer helpers ──────────────────────────────────────────────────────

// renegotiate enqueues a renegotiation request. Non-blocking, coalescing.
func (p *sfuPeer) renegotiate() {
	select {
	case p.negCh <- struct{}{}:
	default:
		// Already queued — this is fine, the loop will pick up all track changes.
	}
}

// doRenegotiate creates a new SDP offer and sends it to the browser.
func (p *sfuPeer) doRenegotiate() {
	// Small delay to coalesce rapid track additions.
	time.Sleep(50 * time.Millisecond)

	p.pcMu.Lock()
	if p.pc == nil {
		p.pcMu.Unlock()
		return
	}

	// Add any new room tracks that aren't yet on this PC.
	if p.room != nil {
		existingSenders := p.pc.GetSenders()
		existingTrackIDs := make(map[string]bool)
		for _, s := range existingSenders {
			if t := s.Track(); t != nil {
				existingTrackIDs[t.ID()] = true
			}
		}
		for _, t := range p.room.snapshot() {
			if t.StreamID() == p.id {
				continue // don't subscribe to our own tracks
			}
			if !existingTrackIDs[t.ID()] {
				if _, err := p.pc.AddTrack(t); err != nil {
					log.Printf("[SFU] peer %s AddTrack %s: %v", p.id, t.ID(), err)
				}
			}
		}
	}

	offer, err := p.pc.CreateOffer(nil)
	if err != nil {
		p.pcMu.Unlock()
		log.Printf("[SFU] peer %s CreateOffer: %v", p.id, err)
		return
	}

	gatherDone := webrtc.GatheringCompletePromise(p.pc)
	if err := p.pc.SetLocalDescription(offer); err != nil {
		p.pcMu.Unlock()
		log.Printf("[SFU] peer %s SetLocalDescription: %v", p.id, err)
		return
	}
	p.pcMu.Unlock()

	// Wait for ICE gathering to complete before sending the offer so the SDP
	// already contains all candidates (avoids trickle-ICE complexity in the client).
	<-gatherDone

	p.pcMu.Lock()
	ld := p.pc.LocalDescription()
	p.pcMu.Unlock()

	p.sendJSON(Message{
		Type:    TypeSFUOffer,
		Payload: mustMarshal(map[string]string{"sdp": ld.SDP}),
	})
	log.Printf("[SFU] peer %s ← offer sent", p.id)
}

func (p *sfuPeer) handleAnswer(answer webrtc.SessionDescription) {
	p.pcMu.Lock()
	defer p.pcMu.Unlock()
	if p.pc == nil {
		return
	}
	if err := p.pc.SetRemoteDescription(answer); err != nil {
		log.Printf("[SFU] peer %s SetRemoteDescription: %v", p.id, err)
	}
}

func (p *sfuPeer) handleICE(init webrtc.ICECandidateInit) {
	p.pcMu.Lock()
	defer p.pcMu.Unlock()
	if p.pc == nil {
		return
	}
	if err := p.pc.AddICECandidate(init); err != nil {
		log.Printf("[SFU] peer %s AddICECandidate: %v", p.id, err)
	}
}