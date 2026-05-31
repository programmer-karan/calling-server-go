import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'signaling.dart';

/// Callback fired when a remote peer's MediaStream is received or removed.
typedef OnRemoteStream = void Function(String peerId, MediaStream? stream);

/// Callback fired when call state changes.
typedef OnCallStateChanged = void Function(CallState state);

/// Callback fired on events (for logging/debugging).
typedef OnCallEvent = void Function(String event, String level);

enum CallState { idle, connecting, connected, reconnecting, ended }

/// P2P calling client using the signaling relay server.
///
/// Usage:
/// ```dart
/// final client = P2PCallClient(serverUrl: 'http://your-server:8080');
/// client.onRemoteStream = (peerId, stream) { /* show remote video */ };
/// client.onLocalStream = (stream) { /* show local video */ };
/// await client.connect();
/// await client.joinRoom('my-room');
/// // ...
/// await client.leaveRoom();
/// client.dispose();
/// ```
class P2PCallClient {
  final String serverUrl;

  /// ICE servers fetched from the Go server's /api/ice-config endpoint.
  List<Map<String, dynamic>>? _iceServers;

  late final SignalingClient _signaling;
  StreamSubscription? _msgSub;

  MediaStream? localStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, List<RTCIceCandidate>> _iceBuf = {};
  final Map<String, List<RTCIceCandidate>> _earlyIce = {};

  String? _currentRoom;
  bool _disposed = false;

  // ── Callbacks ──────────────────────────────────────────────────────────────
  OnRemoteStream? onRemoteStream;
  void Function(MediaStream stream)? onLocalStream;
  OnCallStateChanged? onCallStateChanged;
  OnCallEvent? onEvent;

  String? get myPeerId => _signaling.myPeerId;
  String? get currentRoom => _currentRoom;

  P2PCallClient({required this.serverUrl}) {
    _signaling = SignalingClient(serverUrl: serverUrl, isSfu: false);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Connect to the signaling server and fetch ICE config.
  Future<void> connect() async {
    await _fetchIceConfig();
    _signaling.connect();
    _msgSub = _signaling.onMessage.listen(_onMessage);
    _log('Connected to signaling server', 'info');
  }

  /// Acquire local camera/mic and join a room.
  Future<void> joinRoom(String roomId, {bool video = true, bool audio = true}) async {
    _currentRoom = roomId;
    onCallStateChanged?.call(CallState.connecting);

    // Acquire local media.
    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        'video': video
            ? {'width': 1280, 'height': 720, 'frameRate': 30}
            : false,
        'audio': audio,
      });
      onLocalStream?.call(localStream!);
    } catch (e) {
      _log('getUserMedia failed: $e', 'error');
      // Try audio-only fallback.
      try {
        localStream = await navigator.mediaDevices.getUserMedia({
          'video': false,
          'audio': true,
        });
        onLocalStream?.call(localStream!);
      } catch (e2) {
        _log('Audio-only failed too: $e2', 'error');
      }
    }

    _signaling.joinRoom(roomId);
    _log('Joined room "$roomId"', 'ok');
  }

  /// Leave the current room, close all peer connections.
  Future<void> leaveRoom() async {
    _signaling.leaveRoom();

    for (final pc in _peerConnections.values) {
      await pc.close();
    }
    _peerConnections.clear();
    _iceBuf.clear();
    _earlyIce.clear();

    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    _currentRoom = null;
    onCallStateChanged?.call(CallState.ended);
    _log('Left room', 'warn');
  }

  /// Toggle microphone on/off.
  void toggleMic(bool enabled) {
    localStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
  }

  /// Toggle camera on/off.
  void toggleCamera(bool enabled) {
    localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  /// Switch camera (front/back).
  Future<void> switchCamera() async {
    final videoTrack = localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  /// Release all resources.
  void dispose() {
    _disposed = true;
    _msgSub?.cancel();
    leaveRoom();
    _signaling.dispose();
  }

  // ── Message handler ────────────────────────────────────────────────────────

  void _onMessage(SignalMessage msg) {
    switch (msg.type) {
      case SignalType.peerId:
        _log('Peer ID assigned: ${_signaling.myPeerId}', 'ok');
        break;

      case SignalType.peersList:
        final peers = (msg.payload?['peers'] as List?)?.cast<String>() ?? [];
        _log('Existing peers: $peers', 'info');
        for (final pid in peers) {
          _initiateOffer(pid);
        }
        break;

      case SignalType.peerJoined:
        _log('Peer joined: ${msg.from}', 'ok');
        break;

      case SignalType.peerLeft:
        _log('Peer left: ${msg.from}', 'warn');
        _removePeer(msg.from!);
        break;

      case SignalType.offer:
        _handleOffer(msg.from!, msg.payload!);
        break;

      case SignalType.answer:
        _handleAnswer(msg.from!, msg.payload!);
        break;

      case SignalType.iceCandidate:
        _handleIce(msg.from!, msg.payload!);
        break;

      case SignalType.error:
        _log('Server error: ${msg.payload?['message']}', 'error');
        break;
    }
  }

  // ── PeerConnection management ──────────────────────────────────────────────

  Future<RTCPeerConnection> _createPC(String peerId) async {
    if (_peerConnections.containsKey(peerId)) {
      return _peerConnections[peerId]!;
    }

    final config = {
      'iceServers': _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}],
      'sdpSemantics': 'unified-plan',
    };

    final pc = await createPeerConnection(config);
    _peerConnections[peerId] = pc;
    _iceBuf[peerId] = [];

    // Add local tracks.
    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        await pc.addTrack(track, localStream!);
      }
    }

    // ICE candidates → relay.
    pc.onIceCandidate = (candidate) {
      _signaling.send(SignalMessage(
        type: SignalType.iceCandidate,
        to: peerId,
        payload: {'candidate': candidate.toMap()},
      ));
    };

    // Remote tracks.
    pc.onTrack = (event) {
      _log('Track from $peerId: ${event.track.kind}', 'ok');
      if (event.streams.isNotEmpty) {
        onRemoteStream?.call(peerId, event.streams[0]);
      }
    };

    // Connection state.
    pc.onConnectionState = (state) {
      _log('[$peerId] → $state', 'info');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onCallStateChanged?.call(CallState.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _removePeer(peerId);
      }
    };

    // Flush early ICE.
    final early = _earlyIce.remove(peerId);
    if (early != null) {
      for (final c in early) {
        await pc.addCandidate(c);
      }
    }

    return pc;
  }

  Future<void> _initiateOffer(String peerId) async {
    final pc = await _createPC(peerId);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    _signaling.send(SignalMessage(
      type: SignalType.offer,
      to: peerId,
      payload: {'sdp': offer.toMap()},
    ));
    _log('Offer → $peerId', 'signal');
  }

  Future<void> _handleOffer(String peerId, Map<String, dynamic> payload) async {
    final pc = await _createPC(peerId);
    final sdp = RTCSessionDescription(
      payload['sdp']['sdp'] as String,
      payload['sdp']['type'] as String,
    );
    await pc.setRemoteDescription(sdp);
    await _drainIceBuf(peerId);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    _signaling.send(SignalMessage(
      type: SignalType.answer,
      to: peerId,
      payload: {'sdp': answer.toMap()},
    ));
    _log('Answer → $peerId', 'signal');
  }

  Future<void> _handleAnswer(String peerId, Map<String, dynamic> payload) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    final sdp = RTCSessionDescription(
      payload['sdp']['sdp'] as String,
      payload['sdp']['type'] as String,
    );
    await pc.setRemoteDescription(sdp);
    await _drainIceBuf(peerId);
  }

  Future<void> _handleIce(String peerId, Map<String, dynamic> payload) async {
    final candidateMap = payload['candidate'] as Map<String, dynamic>?;
    if (candidateMap == null) return;

    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String?,
      candidateMap['sdpMid'] as String?,
      candidateMap['sdpMLineIndex'] as int?,
    );

    final pc = _peerConnections[peerId];
    if (pc == null) {
      _earlyIce.putIfAbsent(peerId, () => []).add(candidate);
      return;
    }

    if (pc.getRemoteDescription() != null) {
      await pc.addCandidate(candidate);
    } else {
      _iceBuf.putIfAbsent(peerId, () => []).add(candidate);
    }
  }

  Future<void> _drainIceBuf(String peerId) async {
    final buf = _iceBuf[peerId];
    if (buf == null) return;
    while (buf.isNotEmpty) {
      await _peerConnections[peerId]?.addCandidate(buf.removeAt(0));
    }
  }

  void _removePeer(String peerId) {
    _peerConnections[peerId]?.close();
    _peerConnections.remove(peerId);
    _iceBuf.remove(peerId);
    onRemoteStream?.call(peerId, null);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _fetchIceConfig() async {
    try {
      final res = await http.get(Uri.parse('$serverUrl/api/ice-config'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final servers = data['iceServers'] as List?;
        if (servers != null) {
          _iceServers = servers.cast<Map<String, dynamic>>();
        }
        _log('ICE config loaded from server', 'ok');
      }
    } catch (e) {
      _log('ICE config fetch failed: $e', 'warn');
    }
  }

  void _log(String msg, String level) {
    onEvent?.call(msg, level);
  }
}
