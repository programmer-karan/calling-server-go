# calling-server-go

WebRTC Signaling + SFU server built in Go, with a ready-to-use Flutter/Dart client.

## Features

- **P2P Relay** — Browser-to-browser via WebSocket signaling relay
- **SFU (pion/webrtc)** — Server-mediated track forwarding for group calls
- **Flutter/Dart Client** — Drop-in calling library for mobile apps
- **Built-in Web UI** — Test frontend at `http://localhost:8080`

## Quick Start

```bash
# Run locally
go build -o server . && ./server

# Or with Docker
docker compose up --build
```

Server starts at `http://localhost:8080`

## API Endpoints

| Endpoint | Description |
|---|---|
| `GET /` | Web frontend |
| `WS /ws` | P2P signaling relay |
| `WS /ws/sfu` | SFU (pion/webrtc) |
| `GET /api/ice-config` | ICE/TURN server config |
| `GET /api/rooms` | List active rooms |
| `GET /api/health` | Health check |

## Flutter/Dart Client

The `dart_client/` directory contains a ready-to-use Flutter package.

### Setup

Add to your Flutter app's `pubspec.yaml`:

```yaml
dependencies:
  calling_client:
    path: path/to/dart_client
```

### P2P Call (2 participants)

```dart
import 'package:calling_client/calling_client.dart';

final client = P2PCallClient(serverUrl: 'http://YOUR_SERVER:8080');

client.onLocalStream = (stream) {
  localRenderer.srcObject = stream;
};

client.onRemoteStream = (peerId, stream) {
  remoteRenderer.srcObject = stream;
};

await client.connect();
await client.joinRoom('my-room');

// Controls
client.toggleMic(false);
client.toggleCamera(false);
await client.switchCamera();

// Cleanup
await client.leaveRoom();
client.dispose();
```

### SFU Call (group calls)

```dart
import 'package:calling_client/calling_client.dart';

final client = SfuCallClient(serverUrl: 'http://YOUR_SERVER:8080');

client.onLocalStream = (stream) { /* show local video */ };
client.onRemoteStream = (streamId, stream) { /* show/remove remote video */ };

await client.connect();
await client.joinRoom('team-standup');

await client.leaveRoom();
client.dispose();
```

### Full Example Screens

See `dart_client/lib/src/example_screens.dart` for complete Flutter widgets with video grid, controls, and dark theme.

## Environment Variables

| Variable | Description |
|---|---|
| `ICE_SERVERS` | JSON array of ICE server objects for TURN support |

Example:
```bash
ICE_SERVERS='[{"urls":["turn:your-server:3478"],"username":"user","credential":"pass"}]' ./server
```

## Architecture

```
Browser A ──WS──► Go Server (signaling relay) ──WS──► Browser B
                      │
Browser C ──WS/SFU──► SFU (pion/webrtc) ──RTP──► Browser D
                      │                  ──RTP──► Browser E
```

## License

MIT
