import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/playback/application/playback_realtime_coordinator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeMusicApi extends MusicApi {
  _FakeMusicApi() : socketChannel = _FakeWebSocketChannel();

  final _FakeWebSocketChannel socketChannel;
  bool throwOnOpenSocket = false;

  @override
  WebSocketChannel openSocket() {
    if (throwOnOpenSocket) {
      throw Exception('offline');
    }
    return socketChannel;
  }
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final _FakeWebSocketSink _sink = _FakeWebSocketSink();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready async {}

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  Future<void> emit(dynamic message) async {
    _controller.add(message);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emitError(Object error) async {
    _controller.addError(error);
    await Future<void>.delayed(Duration.zero);
  }

  bool get isClosed => _sink.isClosed;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  final Completer<void> _done = Completer<void>();
  bool isClosed = false;

  @override
  void add(dynamic event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (isClosed) {
      return;
    }
    isClosed = true;
    _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PlaybackRealtimeCoordinator', () {
    test('connect decodes websocket state payloads and dispatches them', () async {
      final api = _FakeMusicApi();
      final receivedPayloads = <Map<String, dynamic>>[];
      final coordinator = PlaybackRealtimeCoordinator(
        api: api,
        onPlaybackEnded: () async {},
        onLibraryChanged: () async {},
        onStatePayload: receivedPayloads.add,
        onError: (_) {},
        onPositionPoll: () async {},
      );

      await coordinator.connect();
      await api.socketChannel.emit(
        jsonEncode(<String, dynamic>{
          'type': 'state_changed',
          'payload': <String, dynamic>{'status': 'playing'},
        }),
      );

      expect(receivedPayloads, <Map<String, dynamic>>[
        <String, dynamic>{'status': 'playing'},
      ]);
    });

    test('connect routes playback ended and library changed events', () async {
      final api = _FakeMusicApi();
      var playbackEndedCalls = 0;
      var libraryChangedCalls = 0;
      final coordinator = PlaybackRealtimeCoordinator(
        api: api,
        onPlaybackEnded: () async {
          playbackEndedCalls += 1;
        },
        onLibraryChanged: () async {
          libraryChangedCalls += 1;
        },
        onStatePayload: (_) {},
        onError: (_) {},
        onPositionPoll: () async {},
      );

      await coordinator.connect();
      await api.socketChannel.emit(
        <String, dynamic>{'type': 'playback_ended'},
      );
      await api.socketChannel.emit(
        <String, dynamic>{'type': 'library_changed'},
      );
      await api.socketChannel.emit(
        <String, dynamic>{'type': 'files_changed'},
      );

      expect(playbackEndedCalls, 1);
      expect(libraryChangedCalls, 2);
    });

    test('connect surfaces websocket and server errors', () async {
      final api = _FakeMusicApi();
      final errors = <String>[];
      final coordinator = PlaybackRealtimeCoordinator(
        api: api,
        onPlaybackEnded: () async {},
        onLibraryChanged: () async {},
        onStatePayload: (_) {},
        onError: errors.add,
        onPositionPoll: () async {},
      );

      await coordinator.connect();
      await api.socketChannel.emit(
        <String, dynamic>{
          'type': 'error',
          'payload': <String, dynamic>{'message': 'Server exploded'},
        },
      );
      await api.socketChannel.emitError(Exception('socket offline'));

      expect(errors, hasLength(2));
      expect(errors.first, 'Server exploded');
      expect(errors.last, contains('WebSocket unavailable'));
    });

    test('connect surfaces openSocket failures', () async {
      final api = _FakeMusicApi()..throwOnOpenSocket = true;
      final errors = <String>[];
      final coordinator = PlaybackRealtimeCoordinator(
        api: api,
        onPlaybackEnded: () async {},
        onLibraryChanged: () async {},
        onStatePayload: (_) {},
        onError: errors.add,
        onPositionPoll: () async {},
      );

      await coordinator.connect();

      expect(errors.single, contains('WebSocket unavailable'));
    });

    test('startPositionPolling triggers callback until disconnect', () async {
      final api = _FakeMusicApi();
      var pollCalls = 0;
      final coordinator = PlaybackRealtimeCoordinator(
        api: api,
        onPlaybackEnded: () async {},
        onLibraryChanged: () async {},
        onStatePayload: (_) {},
        onError: (_) {},
        onPositionPoll: () async {
          pollCalls += 1;
        },
        pollInterval: const Duration(milliseconds: 10),
      );
      final startedCoordinator = coordinator;

      // ignore: cascade_invocations
      startedCoordinator.startPositionPolling();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      final beforeDisconnect = pollCalls;
      expect(beforeDisconnect, greaterThanOrEqualTo(1));

      await coordinator.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(pollCalls, beforeDisconnect);
    });

    test('disconnect closes websocket resources', () async {
      final api = _FakeMusicApi();
      final coordinator = PlaybackRealtimeCoordinator(
        api: api,
        onPlaybackEnded: () async {},
        onLibraryChanged: () async {},
        onStatePayload: (_) {},
        onError: (_) {},
        onPositionPoll: () async {},
      );

      await coordinator.connect();
      await coordinator.disconnect();

      expect(api.socketChannel.isClosed, isTrue);
    });
  });
}
