import 'dart:async';
import 'dart:convert';

import 'package:music_remote_app/core/network/music_api.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class PlaybackRealtimeCoordinator {
  PlaybackRealtimeCoordinator({
    required MusicApi api,
    required Future<void> Function() onPlaybackEnded,
    required Future<void> Function() onLibraryChanged,
    required void Function(Map<String, dynamic> payload) onStatePayload,
    required void Function(String message) onError,
    required Future<void> Function() onPositionPoll,
    this.pollInterval = const Duration(milliseconds: 1200),
  }) : _api = api,
       _onPlaybackEnded = onPlaybackEnded,
       _onLibraryChanged = onLibraryChanged,
       _onStatePayload = onStatePayload,
       _onError = onError,
       _onPositionPoll = onPositionPoll;

  final MusicApi _api;
  final Future<void> Function() _onPlaybackEnded;
  final Future<void> Function() _onLibraryChanged;
  final void Function(Map<String, dynamic> payload) _onStatePayload;
  final void Function(String message) _onError;
  final Future<void> Function() _onPositionPoll;
  final Duration pollInterval;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _positionTimer;

  Future<void> connect() async {
    await _subscription?.cancel();
    await _channel?.sink.close();

    try {
      _channel = _api.openSocket();
      _subscription = _channel!.stream.listen(
        (message) {
          final decoded = _tryDecode(message);
          if (decoded is Map<String, dynamic>) {
            unawaited(_handleWsEvent(decoded));
          }
        },
        onError: (Object error) {
          _onError(
            'WebSocket unavailable. REST controls still work. Details: $error',
          );
        },
      );
    } catch (error) {
      _onError(
        'WebSocket unavailable. REST controls still work. Details: $error',
      );
    }
  }

  void startPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(
      pollInterval,
      (_) => unawaited(_onPositionPoll()),
    );
  }

  Future<void> disconnect() async {
    _positionTimer?.cancel();
    _positionTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  dynamic _tryDecode(dynamic message) {
    if (message is String) {
      try {
        return jsonDecode(message);
      } catch (_) {
        return message;
      }
    }
    return message;
  }

  Future<void> _handleWsEvent(Map<String, dynamic> event) async {
    final eventType =
        event['type']?.toString() ?? event['event']?.toString() ?? '';
    final payload = event['payload'];

    if (eventType == 'playback_ended') {
      await _onPlaybackEnded();
      return;
    }

    if (eventType == 'state_changed' ||
        eventType == 'track_changed' ||
        eventType == 'seek_changed' ||
        payload is Map<String, dynamic>) {
      if (payload is Map<String, dynamic>) {
        _onStatePayload(payload);
      }
    }

    if (eventType == 'library_changed' || eventType == 'files_changed') {
      await _onLibraryChanged();
    }

    if (eventType == 'error') {
      if (payload is Map<String, dynamic>) {
        _onError(payload['message']?.toString() ?? 'Server error');
      } else {
        _onError(event['message']?.toString() ?? 'Server error');
      }
    }
  }
}
