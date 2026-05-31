import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Message types used by the signaling protocol.
class SignalType {
  // Server → Client
  static const peerId = 'peer-id';
  static const peersList = 'peers-list';
  static const peerJoined = 'peer-joined';
  static const peerLeft = 'peer-left';
  static const error = 'error';

  // Client → Server
  static const join = 'join';
  static const leave = 'leave';

  // Both directions – P2P relay
  static const offer = 'offer';
  static const answer = 'answer';
  static const iceCandidate = 'ice-candidate';

  // SFU-specific
  static const sfuJoin = 'sfu-join';
  static const sfuOffer = 'sfu-offer';
  static const sfuAnswer = 'sfu-answer';
  static const sfuIce = 'sfu-ice';
  static const sfuPeerJoined = 'sfu-peer-joined';
  static const sfuPeerLeft = 'sfu-peer-left';
}

/// Envelope matching the Go server's Message struct.
class SignalMessage {
  final String type;
  final String? from;
  final String? to;
  final String? room;
  final Map<String, dynamic>? payload;

  const SignalMessage({
    required this.type,
    this.from,
    this.to,
    this.room,
    this.payload,
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      type: json['type'] as String,
      from: json['from'] as String?,
      to: json['to'] as String?,
      room: json['room'] as String?,
      payload: json['payload'] is Map
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'type': type};
    if (from != null) m['from'] = from;
    if (to != null) m['to'] = to;
    if (room != null) m['room'] = room;
    if (payload != null) m['payload'] = payload;
    return m;
  }
}

/// Low-level WebSocket signaling client.
///
/// Connects to the Go server's `/ws` (P2P) or `/ws/sfu` (SFU) endpoint,
/// sends/receives JSON messages, and handles auto-reconnection.
class SignalingClient {
  final String serverUrl;
  final bool isSfu;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;

  String? myPeerId;

  /// Fires for every inbound [SignalMessage].
  final _messageController = StreamController<SignalMessage>.broadcast();
  Stream<SignalMessage> get onMessage => _messageController.stream;

  /// Fires when the WebSocket connection state changes.
  final _stateController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionState => _stateController.stream;

  bool get isConnected => _channel != null;

  SignalingClient({
    required this.serverUrl,
    this.isSfu = false,
  });

  /// Connect to the signaling server.
  void connect() {
    if (_disposed) return;
    _close();

    final wsPath = isSfu ? '/ws/sfu' : '/ws';
    final uri = Uri.parse('$serverUrl$wsPath');
    final wsUri = uri.replace(
      scheme: uri.scheme == 'https' ? 'wss' : 'ws',
    );

    try {
      _channel = WebSocketChannel.connect(wsUri);
      _stateController.add(true);

      _sub = _channel!.stream.listen(
        (data) {
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            final msg = SignalMessage.fromJson(json);

            // Capture our peer ID automatically.
            if (msg.type == SignalType.peerId && msg.payload != null) {
              myPeerId = msg.payload!['id'] as String?;
            }

            _messageController.add(msg);
          } catch (e) {
            // Malformed message — skip.
          }
        },
        onError: (_) => _scheduleReconnect(),
        onDone: () {
          _stateController.add(false);
          _scheduleReconnect();
        },
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  /// Send a [SignalMessage] to the server.
  void send(SignalMessage msg) {
    _channel?.sink.add(jsonEncode(msg.toJson()));
  }

  /// Convenience: join a room.
  void joinRoom(String roomId) {
    if (isSfu) {
      send(SignalMessage(
        type: SignalType.sfuJoin,
        payload: {'room': roomId},
      ));
    } else {
      send(SignalMessage(
        type: SignalType.join,
        payload: {'room': roomId},
      ));
    }
  }

  /// Convenience: leave the current room.
  void leaveRoom() {
    send(const SignalMessage(type: SignalType.leave));
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), connect);
  }

  void _close() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  /// Release all resources. The client cannot be reused after this.
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _close();
    _messageController.close();
    _stateController.close();
  }
}
