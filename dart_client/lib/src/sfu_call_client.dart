import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'signaling.dart';

/// Callback fired when a remote peer's MediaStream is received or removed.
typedef OnSfuRemoteStream = void Function(String streamId, MediaStream? stream);

/// Callback fired when call state changes.
typedef OnSfuCallStateChanged = void Function(SfuCallState state);

/// Callback fired on events (for logging/debugging).
typedef OnSfuCallEvent = void Function(String event, String level);

enum SfuCallState { idle, connecting, connected, reconnecting, ended }

/// SFU calling client that connects to the Go server's pion/webrtc SFU.
///
/// Unlike P2P, the SFU uses a single PeerConnection per client.
/// The server forwards tracks between all participants.
///
/// Usage:
/// ```dart
/// final client = SfuCallClient(serverUrl: 'http://your-server:8080');
/// client.onRemoteStream = (streamId, stream) { /* show remote video */ };
/// client.onLocalStream = (stream) { /* show local video */ };
/// await client.connect();
/// await client.joinRoom('my-room');
/// // ...
/// await client.leaveRoom();
/// client.dispose();
/// ```
class SfuCallClient {
  final String serverUrl;

  List<Map<String, dynamic>>? _iceServers;

  late final SignalingClient _signaling;
  StreamSubscription? _msgSub;

  MediaStream? localStream;
  RTCPeerConnection? _pc;
  final List<RTCIceCandidate> _iceBuf = [];

  String? _currentRoom;
  bool _disposed = false;

  /// Serializes offer processing so rapid renegotiations don't collide.
  Future<void> _offerQueue = Future.value();

  // ── Callbacks ──────────────────────────────────────────────────────────────
  OnSfuRemoteStream? onRemoteStream;
  void Function(MediaStream stream)? onLocalStream;
  OnSfuCallStateChanged? onCallStateChanged;
  OnSfuCallEvent? onEvent;

  String? get myPeerId => _signaling.myPeerId;
  String? get currentRoom => _currentRoom;

  SfuCallClient({required this.serverUrl}) {
    _signaling = SignalingClient(serverUrl: serverUrl, isSfu: true);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Connect to the SFU signaling server and fetch ICE config.
  Future<void> connect() async {
    await _fetchIceConfig();
    _signaling.connect();
    _msgSub = _signaling.onMessage.listen(_onMessage);
    _log('Connected to SFU signaling', 'info');
  }

  /// Acquire local camera/mic and join a room.
  Future<void> joinRoom(String roomId, {bool video = true, bool audio = true}) async {
    _currentRoom = roomId;
    onCallStateChanged?.call(SfuCallState.connecting);

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

    // Build PeerConnection.
    await _buildPC();

    // The signaling client will send sfu-join when it receives peer-id.
    // If already connected, do it manually.
    if (_signaling.myPeerId != null) {
      _signaling.joinRoom(roomId);
    }

    _log('Joining SFU room "$roomId"', 'ok');
  }

  /// Leave the current room.
  Future<void> leaveRoom() async {
    _signaling.leaveRoom();

    await _pc?.close();
    _pc = null;
    _iceBuf.clear();
    _offerQueue = Future.value();

    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    _currentRoom = null;
    onCallStateChanged?.call(SfuCallState.ended);
    _log('Left SFU room', 'warn');
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
        _log('SFU Peer ID: ${_signaling.myPeerId}', 'ok');
        // Auto-join room if we have one queued.
        if (_currentRoom != null) {
          _signaling.joinRoom(_currentRoom!);
        }
        break;

      case SignalType.sfuOffer:
        final sdp = msg.payload?['sdp'] as String?;
        if (sdp != null) {
          _queueOffer(sdp);
        }
        break;

      case SignalType.sfuIce:
        final candidateMap = msg.payload?['candidate'] as Map<String, dynamic>?;
        if (candidateMap != null) {
          _handleIce(candidateMap);
        }
        break;

      case SignalType.sfuPeerJoined:
        _log('SFU peer joined: ${msg.from}', 'ok');
        break;

      case SignalType.sfuPeerLeft:
        _log('SFU peer left: ${msg.from}', 'warn');
        // Notify UI to remove remote streams from this peer.
        if (msg.from != null) {
          onRemoteStream?.call(msg.from!, null);
        }
        break;

      case SignalType.error:
        _log('Server error: ${msg.payload?['message']}', 'error');
        break;
    }
  }

  // ── PeerConnection ─────────────────────────────────────────────────────────

  Future<void> _buildPC() async {
    await _pc?.close();

    final config = {
      'iceServers': _iceServers ?? [{'urls': 'stun:stun.l.google.com:19302'}],
      'sdpSemantics': 'unified-plan',
    };

    _pc = await createPeerConnection(config);
    _iceBuf.clear();

    // Add local tracks.
    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        await _pc!.addTrack(track, localStream!);
      }
    }

    // ICE candidates → SFU.
    _pc!.onIceCandidate = (candidate) {
      _signaling.send(SignalMessage(
        type: SignalType.sfuIce,
        payload: {'candidate': candidate.toMap()},
      ));
    };

    // Remote tracks from SFU.
    _pc!.onTrack = (event) {
      _log('SFU track: ${event.track.kind}', 'ok');
      if (event.streams.isNotEmpty) {
        final stream = event.streams[0];
        onRemoteStream?.call(stream.id, stream);
      }
    };

    // Connection state.
    _pc!.onConnectionState = (state) {
      _log('SFU PC → $state', 'info');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onCallStateChanged?.call(SfuCallState.connected);
      }
    };
  }

  // ── Offer/answer serialization ─────────────────────────────────────────────

  void _queueOffer(String sdp) {
    _offerQueue = _offerQueue.then((_) => _handleOffer(sdp));
  }

  Future<void> _handleOffer(String sdpStr) async {
    if (_pc == null) await _buildPC();

    try {
      final offer = RTCSessionDescription(sdpStr, 'offer');
      await _pc!.setRemoteDescription(offer);

      // Flush buffered ICE.
      while (_iceBuf.isNotEmpty) {
        await _pc!.addCandidate(_iceBuf.removeAt(0));
      }

      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      _signaling.send(SignalMessage(
        type: SignalType.sfuAnswer,
        payload: {'sdp': answer.sdp},
      ));
      _log('SFU Answer sent', 'signal');
    } catch (e) {
      _log('SFU offer handling failed: $e', 'error');
    }
  }

  void _handleIce(Map<String, dynamic> candidateMap) {
    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String?,
      candidateMap['sdpMid'] as String?,
      candidateMap['sdpMLineIndex'] as int?,
    );

    if (_pc?.getRemoteDescription() != null) {
      _pc!.addCandidate(candidate);
    } else {
      _iceBuf.add(candidate);
    }
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
        _log('ICE config loaded', 'ok');
      }
    } catch (e) {
      _log('ICE config fetch failed: $e', 'warn');
    }
  }

  void _log(String msg, String level) {
    onEvent?.call(msg, level);
  }
}
