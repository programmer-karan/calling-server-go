import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'call_client.dart';

/// Ready-to-use video call screen powered by LiveKit.
///
/// Usage:
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => LiveKitCallScreen(
///     tokenServerUrl: 'http://YOUR_SERVER:8080',
///     roomName: 'my-room',
///     identity: 'Alice',
///   ),
/// ));
/// ```
class LiveKitCallScreen extends StatefulWidget {
  /// URL of your token server (Go server on port 8080).
  final String tokenServerUrl;

  /// Override LiveKit server URL (default: fetched from token server).
  final String? livekitUrl;

  /// Room to join.
  final String roomName;

  /// Display name / identity.
  final String identity;

  const LiveKitCallScreen({
    super.key,
    required this.tokenServerUrl,
    required this.roomName,
    required this.identity,
    this.livekitUrl,
  });

  @override
  State<LiveKitCallScreen> createState() => _LiveKitCallScreenState();
}

class _LiveKitCallScreenState extends State<LiveKitCallScreen> {
  late final LiveKitCallClient _client;
  bool _loading = true;
  bool _micOn = true;
  bool _camOn = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = LiveKitCallClient(
      tokenServerUrl: widget.tokenServerUrl,
      livekitUrlOverride: widget.livekitUrl,
    );
    _client.onParticipantsChanged = (_) => setState(() {});
    _client.onError = (e) => setState(() => _error = e);
    _connect();
  }

  Future<void> _connect() async {
    try {
      await _client.joinRoom(
        room: widget.roomName,
        identity: widget.identity,
      );
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _client.leaveRoom();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070710),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151527),
        title: Row(children: [
          Text(widget.roomName),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF10B981)),
            ),
            child: Text(
              '${_client.remoteParticipants.length + 1} in call',
              style: const TextStyle(fontSize: 10, color: Color(0xFF10B981)),
            ),
          ),
        ]),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF6366F1)))
          : _error != null
              ? _buildError()
              : Column(
                  children: [
                    Expanded(child: _buildVideoGrid()),
                    _buildControls(),
                  ],
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              setState(() { _loading = true; _error = null; });
              _connect();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoGrid() {
    final tiles = <Widget>[];

    // Local video tile.
    final localPart = _client.localParticipant;
    if (localPart != null) {
      tiles.add(_buildParticipantTile(
        localPart,
        '${widget.identity} (You)',
        isLocal: true,
      ));
    }

    // Remote video tiles.
    for (final p in _client.remoteParticipants) {
      tiles.add(_buildParticipantTile(p, p.identity ?? 'Unknown'));
    }

    if (tiles.isEmpty) {
      return const Center(
        child: Text('Waiting for participants...', style: TextStyle(color: Colors.white38)),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(8),
      child: GridView.count(
        crossAxisCount: tiles.length <= 2 ? 1 : 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 16 / 9,
        children: tiles,
      ),
    );
  }

  Widget _buildParticipantTile(Participant participant, String label, {bool isLocal = false}) {
    // Find video track.
    TrackPublication? videoPub;
    for (final pub in participant.videoTrackPublications) {
      if (pub.source == TrackSource.camera) {
        videoPub = pub;
        break;
      }
    }

    final videoTrack = videoPub?.track as VideoTrack?;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video or placeholder.
          Container(
            color: const Color(0xFF0A0A14),
            child: videoTrack != null
                ? VideoTrackRenderer(
                    videoTrack,
                    fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : const Center(
                    child: Icon(Icons.person, color: Colors.white24, size: 64),
                  ),
          ),
          // Name label.
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isLocal
                    ? const Color(0xFF6366F1).withOpacity(0.7)
                    : Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
          // Muted indicator.
          if (participant.isMuted)
            const Positioned(
              top: 8,
              right: 8,
              child: Icon(Icons.mic_off, color: Colors.red, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF151527),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ctrlBtn(
            icon: _micOn ? Icons.mic : Icons.mic_off,
            label: 'Mic',
            active: _micOn,
            onTap: () {
              setState(() => _micOn = !_micOn);
              _client.toggleMic(_micOn);
            },
          ),
          const SizedBox(width: 16),
          _ctrlBtn(
            icon: _camOn ? Icons.videocam : Icons.videocam_off,
            label: 'Camera',
            active: _camOn,
            onTap: () {
              setState(() => _camOn = !_camOn);
              _client.toggleCamera(_camOn);
            },
          ),
          const SizedBox(width: 16),
          _ctrlBtn(
            icon: Icons.cameraswitch,
            label: 'Flip',
            onTap: () => _client.switchCamera(),
          ),
          const SizedBox(width: 16),
          _ctrlBtn(
            icon: Icons.call_end,
            label: 'Leave',
            danger: true,
            onTap: () {
              _client.leaveRoom();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _ctrlBtn({
    required IconData icon,
    required String label,
    bool active = true,
    bool danger = false,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: danger
                  ? Colors.red
                  : active
                      ? const Color(0xFF21213B)
                      : Colors.red.withOpacity(0.2),
              border: Border.all(
                color: danger
                    ? Colors.red
                    : active
                        ? Colors.white24
                        : Colors.red.withOpacity(0.4),
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }
}
