import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:calling_client/calling_client.dart';

/// Example Flutter screen showing a complete video call UI.
///
/// Drop this into your Flutter project. Make sure to add the `calling_client`
/// package as a path dependency in your app's pubspec.yaml:
///
/// ```yaml
/// dependencies:
///   calling_client:
///     path: ../dart_client   # adjust path to your project
/// ```
///
/// Also add these permissions:
///
/// **Android** (android/app/src/main/AndroidManifest.xml):
/// ```xml
/// <uses-permission android:name="android.permission.CAMERA" />
/// <uses-permission android:name="android.permission.RECORD_AUDIO" />
/// <uses-permission android:name="android.permission.INTERNET" />
/// ```
///
/// **iOS** (ios/Runner/Info.plist):
/// ```xml
/// <key>NSCameraUsageDescription</key>
/// <string>Camera is needed for video calls</string>
/// <key>NSMicrophoneUsageDescription</key>
/// <string>Microphone is needed for audio calls</string>
/// ```

// ═══════════════════════════════════════════════════════════════════════════════
// P2P CALL EXAMPLE
// ═══════════════════════════════════════════════════════════════════════════════

class P2PCallScreen extends StatefulWidget {
  final String serverUrl; // e.g. 'http://192.168.1.5:8080'
  final String roomId;
  final String displayName;

  const P2PCallScreen({
    super.key,
    required this.serverUrl,
    required this.roomId,
    this.displayName = 'User',
  });

  @override
  State<P2PCallScreen> createState() => _P2PCallScreenState();
}

class _P2PCallScreenState extends State<P2PCallScreen> {
  late final P2PCallClient _client;

  final _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  bool _micOn = true;
  bool _camOn = true;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();

    _client = P2PCallClient(serverUrl: widget.serverUrl);

    _client.onLocalStream = (stream) {
      setState(() => _localRenderer.srcObject = stream);
    };

    _client.onRemoteStream = (peerId, stream) async {
      if (stream != null) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;
        setState(() => _remoteRenderers[peerId] = renderer);
      } else {
        _remoteRenderers[peerId]?.dispose();
        setState(() => _remoteRenderers.remove(peerId));
      }
    };

    _client.onCallStateChanged = (state) {
      _addLog('Call state: $state');
    };

    _client.onEvent = (event, level) {
      _addLog('[$level] $event');
    };

    await _client.connect();
    await _client.joinRoom(widget.roomId);
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add('${DateTime.now().toIso8601String().substring(11, 19)} $msg');
      if (_logs.length > 100) _logs.removeAt(0);
    });
  }

  @override
  void dispose() {
    _client.dispose();
    _localRenderer.dispose();
    for (final r in _remoteRenderers.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allRenderers = [
      _buildVideoTile('${widget.displayName} (You)', _localRenderer, isLocal: true),
      ..._remoteRenderers.entries.map(
        (e) => _buildVideoTile('Peer ${e.key.substring(0, 6)}', e.value),
      ),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF070710),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151527),
        title: Text('Room: ${widget.roomId}'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Video grid
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: GridView.count(
                crossAxisCount: allRenderers.length <= 2 ? 1 : 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 16 / 9,
                children: allRenderers,
              ),
            ),
          ),
          // Controls
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildVideoTile(String label, RTCVideoRenderer renderer, {bool isLocal = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          Container(
            color: const Color(0xFF0A0A14),
            child: RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: isLocal,
            ),
          ),
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

// ═══════════════════════════════════════════════════════════════════════════════
// SFU CALL EXAMPLE
// ═══════════════════════════════════════════════════════════════════════════════

class SfuCallScreen extends StatefulWidget {
  final String serverUrl;
  final String roomId;
  final String displayName;

  const SfuCallScreen({
    super.key,
    required this.serverUrl,
    required this.roomId,
    this.displayName = 'User',
  });

  @override
  State<SfuCallScreen> createState() => _SfuCallScreenState();
}

class _SfuCallScreenState extends State<SfuCallScreen> {
  late final SfuCallClient _client;

  final _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};

  bool _micOn = true;
  bool _camOn = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();

    _client = SfuCallClient(serverUrl: widget.serverUrl);

    _client.onLocalStream = (stream) {
      setState(() => _localRenderer.srcObject = stream);
    };

    _client.onRemoteStream = (streamId, stream) async {
      if (stream != null) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;
        setState(() => _remoteRenderers[streamId] = renderer);
      } else {
        // Remove all renderers matching this peer prefix.
        final toRemove = _remoteRenderers.keys
            .where((k) => k.startsWith(streamId))
            .toList();
        for (final k in toRemove) {
          _remoteRenderers[k]?.dispose();
          _remoteRenderers.remove(k);
        }
        setState(() {});
      }
    };

    _client.onEvent = (event, level) {
      debugPrint('[SFU] [$level] $event');
    };

    await _client.connect();
    await _client.joinRoom(widget.roomId);
  }

  @override
  void dispose() {
    _client.dispose();
    _localRenderer.dispose();
    for (final r in _remoteRenderers.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allRenderers = [
      _buildVideoTile('${widget.displayName} (You)', _localRenderer, isLocal: true),
      ..._remoteRenderers.entries.map(
        (e) => _buildVideoTile('SFU Peer', e.value),
      ),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF070710),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151527),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Room: ${widget.roomId}'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF6366F1)),
              ),
              child: const Text('SFU', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: GridView.count(
                crossAxisCount: allRenderers.length <= 2 ? 1 : 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 16 / 9,
                children: allRenderers,
              ),
            ),
          ),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildVideoTile(String label, RTCVideoRenderer renderer, {bool isLocal = false}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          Container(
            color: const Color(0xFF0A0A14),
            child: RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: isLocal,
            ),
          ),
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
