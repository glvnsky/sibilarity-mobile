import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/network/music_api.dart';

class PlaybackConnectSyncResult {
  const PlaybackConnectSyncResult({
    required this.health,
    required this.state,
    required this.library,
  });

  final bool health;
  final Map<String, dynamic> state;
  final List<TrackItem> library;
}

class PlaybackRemoteCoordinator {
  PlaybackRemoteCoordinator({required MusicApi api}) : _api = api;

  final MusicApi _api;

  Future<PlaybackConnectSyncResult> connectAndSync({
    required String baseUrl,
    required String accessToken,
  }) async {
    _configure(baseUrl: baseUrl, accessToken: accessToken);
    final (health, state, library) = await (
      _api.health(),
      _api.state(),
      _api.library(),
    ).wait;
    return PlaybackConnectSyncResult(
      health: health,
      state: state,
      library: library,
    );
  }

  Future<Map<String, dynamic>> refreshState({
    required String baseUrl,
    required String accessToken,
  }) async {
    _configure(baseUrl: baseUrl, accessToken: accessToken);
    return _api.state();
  }

  Future<Map<String, dynamic>> refreshPosition({
    required String baseUrl,
    required String accessToken,
  }) async {
    _configure(baseUrl: baseUrl, accessToken: accessToken);
    return _api.position();
  }

  Future<void> sendCommand({
    required String baseUrl,
    required String accessToken,
    required String endpoint,
    Map<String, dynamic>? body,
  }) async {
    _configure(baseUrl: baseUrl, accessToken: accessToken);
    await _api.command(endpoint, body: body);
  }

  Future<void> seek({
    required String baseUrl,
    required String accessToken,
    required double position,
  }) async {
    _configure(baseUrl: baseUrl, accessToken: accessToken);
    await _api.seek(position);
  }

  Future<void> logout({
    required String baseUrl,
    required String accessToken,
  }) async {
    _configure(baseUrl: baseUrl, accessToken: accessToken);
    await _api.logout();
  }

  void _configure({
    required String baseUrl,
    required String accessToken,
  }) {
    _api.configure(baseUrl: baseUrl, token: accessToken);
  }
}
