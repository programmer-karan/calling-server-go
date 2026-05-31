// sfu_client.js — drop-in SFU client for /ws/sfu
// Include this after the existing signaling code in index.html,
// or use the pre-patched index.html provided alongside it.
//
// The SFU client mirrors the relay-mode UI but connects to ws://host/ws/sfu
// and participates in server-side track forwarding.

'use strict';

const SFU = (() => {
    // ── State ─────────────────────────────────────────────────────────────────
    const S = {
        ws: null,
        myId: null,
        pc: null,           // single RTCPeerConnection to the SFU
        room: null,
        localStream: null,
        iceConfig: null,
    };

    // ── Helpers ───────────────────────────────────────────────────────────────
    function log(msg, type = 'default') {
        const body = document.getElementById('log-body');
        if (!body) return;
        const row = document.createElement('div');
        row.className = `log-row ${type}`;
        const now = new Date().toLocaleTimeString('en', { hour12: false });
        row.textContent = `${now}  [SFU] ${msg}`;
        body.appendChild(row);
        body.scrollTop = body.scrollHeight;
    }

    function wsSend(obj) {
        if (S.ws?.readyState === WebSocket.OPEN)
            S.ws.send(JSON.stringify(obj));
    }

    // ── ICE config ────────────────────────────────────────────────────────────
    async function loadIce() {
        try {
            const r = await fetch('/api/ice-config');
            S.iceConfig = await r.json();
        } catch {
            S.iceConfig = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };
        }
    }

    // ── WebSocket ─────────────────────────────────────────────────────────────
    function connect(roomID) {
        S.room = roomID;
        const proto = location.protocol === 'https:' ? 'wss' : 'ws';
        S.ws = new WebSocket(`${proto}://${location.host}/ws/sfu`);
        S.ws.onopen = () => log('WebSocket connected', 'ok');
        S.ws.onclose = () => log('WebSocket closed', 'warn');
        S.ws.onerror = () => log('WebSocket error', 'error');
        S.ws.onmessage = e => {
            try { onMessage(JSON.parse(e.data)); }
            catch (err) { log('Bad JSON: ' + err, 'error'); }
        };
    }

    // ── Message handler ───────────────────────────────────────────────────────
    function onMessage(m) {
        switch (m.type) {
            case 'peer-id':
                S.myId = m.payload.id;
                log(`Assigned peer ID: ${S.myId}`, 'info');
                wsSend({ type: 'sfu-join', payload: { room: S.room } });
                break;

            case 'sfu-offer':
                handleOffer(m.payload.sdp);
                break;

            case 'sfu-ice':
                if (S.pc && m.payload?.candidate) {
                    S.pc.addIceCandidate(m.payload.candidate)
                        .catch(e => log('addICE: ' + e, 'error'));
                }
                break;

            case 'sfu-peer-joined':
                log(`Peer joined room: ${m.from}`, 'ok');
                break;

            case 'sfu-peer-left':
                log(`Peer left room: ${m.from}`, 'warn');
                removePeerVideo(m.from);
                break;

            case 'error':
                log('Server error: ' + m.payload?.message, 'error');
                break;
        }
    }

    // ── PeerConnection ────────────────────────────────────────────────────────
    function buildPC() {
        const pc = new RTCPeerConnection(S.iceConfig);
        S.pc = pc;

        // Send our local media.
        if (S.localStream) {
            S.localStream.getTracks().forEach(t => pc.addTrack(t, S.localStream));
        }

        // ICE trickle.
        pc.onicecandidate = ({ candidate }) => {
            if (candidate) {
                wsSend({ type: 'sfu-ice', payload: { candidate } });
            }
        };

        // Receive forwarded tracks from other peers via SFU.
        pc.ontrack = ({ track, streams }) => {
            log(`Track received: ${track.kind}`, 'ok');
            const stream = streams?.[0];
            // Try to match stream.id to a peer tile, otherwise create one.
            const streamId = stream?.id ?? track.id;
            let vid = document.getElementById(`sfu-vid-${streamId}`);
            if (!vid) {
                vid = createRemoteVideo(streamId);
            }
            if (stream) {
                vid.srcObject = stream;
            } else {
                if (!vid.srcObject) vid.srcObject = new MediaStream();
                vid.srcObject.addTrack(track);
            }
            vid.play().catch(() => { });
        };

        pc.onconnectionstatechange = () =>
            log(`PC state → ${pc.connectionState}`,
                pc.connectionState === 'connected' ? 'ok' :
                pc.connectionState === 'failed' ? 'error' : 'info');

        return pc;
    }

    // ── Offer/answer ──────────────────────────────────────────────────────────
    async function handleOffer(sdpStr) {
        log('Offer ← SFU', 'signal');
        if (!S.pc) buildPC();

        const offer = new RTCSessionDescription({ type: 'offer', sdp: sdpStr });
        await S.pc.setRemoteDescription(offer);
        const answer = await S.pc.createAnswer();
        await S.pc.setLocalDescription(answer);

        wsSend({
            type: 'sfu-answer',
            payload: { sdp: S.pc.localDescription.sdp },
        });
        log('Answer → SFU', 'signal');
    }

    // ── Video tile helpers ────────────────────────────────────────────────────
    function createRemoteVideo(streamId) {
        const grid = document.getElementById('grid');
        if (!grid) return document.createElement('video');

        const tile = document.createElement('div');
        tile.id = `sfu-tile-${streamId}`;
        tile.className = 'tile';

        const vid = document.createElement('video');
        vid.id = `sfu-vid-${streamId}`;
        vid.autoplay = true;
        vid.playsInline = true;

        const lbl = document.createElement('div');
        lbl.className = 'tile-label';
        lbl.textContent = `SFU peer ${streamId.slice(0, 6)}`;

        tile.append(vid, lbl);
        grid.append(tile);
        return vid;
    }

    function removePeerVideo(peerId) {
        // Remove all tiles whose id starts with this peer's id.
        document.querySelectorAll(`[id^="sfu-tile-${peerId}"]`).forEach(el => el.remove());
        document.querySelectorAll(`[id^="sfu-tile-${peerId}-"]`).forEach(el => el.remove());
    }

    // ── Public API ────────────────────────────────────────────────────────────
    async function join(roomID, localStream) {
        S.localStream = localStream;
        await loadIce();
        buildPC();
        connect(roomID);
        log(`Joining SFU room "${roomID}"`, 'info');
    }

    function leave() {
        S.ws?.close();
        S.pc?.close();
        S.pc = null;
        S.ws = null;
        S.room = null;
        log('Left SFU room', 'warn');
    }

    return { join, leave };
})();