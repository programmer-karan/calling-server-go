/// LiveKit-based video calling for Flutter.
///
/// Provides:
/// - [LiveKitCallClient] — High-level API for joining rooms, toggling media
/// - [LiveKitCallScreen] — Drop-in Flutter widget for video calls
/// - [TokenService] — Fetches tokens from the Go token server
library livekit_calling;

export 'src/token_service.dart';
export 'src/call_client.dart';
export 'src/call_screen.dart';
