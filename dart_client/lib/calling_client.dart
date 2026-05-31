/// WebRTC calling client for Flutter — works with the calling-server-go backend.
///
/// Provides two clients:
/// - [P2PCallClient] — Peer-to-peer calling via signaling relay
/// - [SfuCallClient] — Server-mediated calling via pion/webrtc SFU
library calling_client;

export 'src/signaling.dart';
export 'src/p2p_call_client.dart';
export 'src/sfu_call_client.dart';
