import 'dart:convert';
import 'package:http/http.dart' as http;

/// Fetches a LiveKit access token from your token server.
///
/// The token server runs at [tokenServerUrl] and exposes:
///   GET /api/token?room=ROOM&identity=NAME
///
/// Returns a map with:
///   - `token`: JWT string for LiveKit
///   - `url`: LiveKit WebSocket URL (ws://host:7880)
class TokenService {
  final String tokenServerUrl;

  const TokenService({required this.tokenServerUrl});

  /// Fetch a token to join [room] as [identity].
  Future<TokenResponse> getToken({
    required String room,
    required String identity,
  }) async {
    final uri = Uri.parse(
      '$tokenServerUrl/api/token?room=${Uri.encodeComponent(room)}&identity=${Uri.encodeComponent(identity)}',
    );

    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Token server error: ${res.statusCode} ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return TokenResponse(
      token: data['token'] as String,
      url: data['url'] as String,
    );
  }
}

class TokenResponse {
  final String token;
  final String url;

  const TokenResponse({required this.token, required this.url});
}
