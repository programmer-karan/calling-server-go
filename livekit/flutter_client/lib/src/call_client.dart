import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'token_service.dart';

/// Callback for remote participant track changes.
typedef OnParticipantChanged = void Function(List<RemoteParticipant> participants);

/// High-level LiveKit calling client.
///
/// Wraps the official `livekit_client` SDK with a simple API for calling.
///
/// ```dart
/// final client = LiveKitCallClient(tokenServerUrl: 'http://YOUR_SERVER:8080');
/// await client.joinRoom(room: 'my-room', identity: 'Alice');
/// // ... call in progress ...
/// await client.leaveRoom();
/// client.dispose();
/// ```
class LiveKitCallClient {
  final String tokenServerUrl;

  /// Override the LiveKit server URL (default: fetched from token server).
  final String? livekitUrlOverride;

  late final TokenService _tokenService;

  Room? _room;
  EventsListener<RoomEvent>? _listener;

  // ── Public state ───────────────────────────────────────────────────────────
  Room? get room => _room;
  LocalParticipant? get localParticipant => _room?.localParticipant;
  List<RemoteParticipant> get remoteParticipants =>
      _room?.remoteParticipants.values.toList() ?? [];

  bool get isConnected => _room?.connectionState == ConnectionState.connected;

  // ── Callbacks ──────────────────────────────────────────────────────────────
  /// Called when a remote participant joins, leaves, or their tracks change.
  OnParticipantChanged? onParticipantsChanged;

  /// Called when connection state changes.
  void Function(ConnectionState state)? onConnectionStateChanged;

  /// Called on errors.
  void Function(String error)? onError;

  /// Called for log events.
  void Function(String msg)? onLog;

  LiveKitCallClient({
    required this.tokenServerUrl,
    this.livekitUrlOverride,
  }) {
    _tokenService = TokenService(tokenServerUrl: tokenServerUrl);
  }

  // ── Join / Leave ───────────────────────────────────────────────────────────

  /// Join a room. Acquires camera+mic and connects to LiveKit.
  Future<void> joinRoom({
    required String room,
    required String identity,
    bool video = true,
    bool audio = true,
  }) async {
    _log('Fetching token for room "$room"...');

    // 1. Get token from server.
    final tokenRes = await _tokenService.getToken(room: room, identity: identity);
    final url = livekitUrlOverride ?? tokenRes.url;

    _log('Connecting to LiveKit at $url');

    // 2. Create room and connect.
    _room = Room();
    _setupListeners();

    try {
      await _room!.connect(
        url,
        tokenRes.token,
        roomOptions: RoomOptions(
          defaultCameraCaptureOptions: CameraCaptureOptions(
            params: VideoParametersPresets.h720_169,
          ),
          defaultAudioCaptureOptions: const AudioCaptureOptions(
            noiseSuppression: true,
            echoCancellation: true,
          ),
          defaultVideoPublishOptions: const VideoPublishOptions(
            simulcast: true,
          ),
        ),
      );

      // 3. Enable camera and mic.
      if (video) {
        await _room!.localParticipant?.setCameraEnabled(true);
      }
      if (audio) {
        await _room!.localParticipant?.setMicrophoneEnabled(true);
      }

      _log('Connected to room "$room" as "$identity"');
    } catch (e) {
      _log('Connection failed: $e');
      onError?.call(e.toString());
      rethrow;
    }
  }

  /// Leave the current room and release all resources.
  Future<void> leaveRoom() async {
    _listener?.dispose();
    _listener = null;
    await _room?.disconnect();
    await _room?.dispose();
    _room = null;
    _log('Left room');
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  /// Toggle camera on/off.
  Future<void> toggleCamera(bool enabled) async {
    await _room?.localParticipant?.setCameraEnabled(enabled);
    _log('Camera ${enabled ? "on" : "off"}');
  }

  /// Toggle microphone on/off.
  Future<void> toggleMic(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
    _log('Mic ${enabled ? "on" : "off"}');
  }

  /// Switch between front and back camera.
  Future<void> switchCamera() async {
    final videoTrack = _room?.localParticipant?.videoTrackPublications
        .firstOrNull?.track as LocalVideoTrack?;
    if (videoTrack != null) {
      // Get current device and switch
      final devices = await Hardware.instance.enumerateDevices('videoinput');
      if (devices.length > 1) {
        final currentDeviceId = videoTrack.currentOptions.deviceId;
        final nextDevice = devices.firstWhere(
          (d) => d.deviceId != currentDeviceId,
          orElse: () => devices.first,
        );
        await videoTrack.setCameraPosition(
          nextDevice.deviceId == devices.first.deviceId
              ? CameraPosition.front
              : CameraPosition.back,
        );
        _log('Camera switched');
      }
    }
  }

  /// Enable/disable screen sharing.
  Future<void> toggleScreenShare(bool enabled) async {
    await _room?.localParticipant?.setScreenShareEnabled(enabled);
    _log('Screen share ${enabled ? "on" : "off"}');
  }

  // ── Listeners ──────────────────────────────────────────────────────────────

  void _setupListeners() {
    _listener = _room!.createListener();

    _listener!
      ..on<RoomDisconnectedEvent>((event) {
        _log('Room disconnected');
        onConnectionStateChanged?.call(ConnectionState.disconnected);
      })
      ..on<ParticipantConnectedEvent>((event) {
        _log('Participant joined: ${event.participant.identity}');
        _notifyParticipants();
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _log('Participant left: ${event.participant.identity}');
        _notifyParticipants();
      })
      ..on<TrackSubscribedEvent>((event) {
        _log('Track subscribed: ${event.track.kind} from ${event.participant.identity}');
        _notifyParticipants();
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _log('Track unsubscribed: ${event.track.kind}');
        _notifyParticipants();
      })
      ..on<RoomReconnectingEvent>((event) {
        _log('Reconnecting...');
        onConnectionStateChanged?.call(ConnectionState.reconnecting);
      })
      ..on<RoomReconnectedEvent>((event) {
        _log('Reconnected');
        onConnectionStateChanged?.call(ConnectionState.connected);
      });
  }

  void _notifyParticipants() {
    onParticipantsChanged?.call(remoteParticipants);
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  void dispose() {
    _listener?.dispose();
    _room?.dispose();
    _room = null;
  }

  void _log(String msg) {
    debugPrint('[LiveKit] $msg');
    onLog?.call(msg);
  }
}
