import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/playback_queue/application/playback_session_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_service.dart';

class _RecordingMusicApi extends MusicApi {
  final List<({String endpoint, Map<String, dynamic>? body})> commands =
      <({String endpoint, Map<String, dynamic>? body})>[];

  @override
  Future<void> command(String endpoint, {Map<String, dynamic>? body}) async {
    commands.add((endpoint: endpoint, body: body));
  }
}

void main() {
  group('PlaybackSessionService', () {
    late _RecordingMusicApi api;
    late PlaybackSessionService service;

    setUp(() {
      api = _RecordingMusicApi();
      service =
          PlaybackSessionService(api: api, queueService: PlaybackQueueService())
            ..setLibrary(const <TrackItem>[
              TrackItem(id: 'a', title: 'A'),
              TrackItem(id: 'b', title: 'B'),
              TrackItem(id: 'c', title: 'C'),
              TrackItem(id: 'd', title: 'D'),
            ]);
    });

    test('playLibraryTrack rebuilds queue and plays clicked track', () async {
      final result = await service.playLibraryTrack(
        const TrackItem(id: 'c', title: 'C'),
      );

      expect(result.trackIdToPlay, 'c');
      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'c',
        'd',
      ]);
      expect(api.commands, hasLength(1));
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'c'});
    });

    test(
      'playQueueOrBootstrapDefault starts first library track on empty queue',
      () async {
        final result = await service.playQueueOrBootstrapDefault();

        expect(result.trackIdToPlay, 'a');
        expect(service.snapshot().currentTrackId, 'a');
        expect(api.commands.single.endpoint, '/api/play');
        expect(api.commands.single.body, <String, dynamic>{'track_id': 'a'});
      },
    );

    test('playNext consumes current entry and plays next track', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      api.commands.clear();

      final result = await service.playNext();

      expect(result.trackIdToPlay, 'c');
      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'c',
        'd',
      ]);
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'c'});
    });

    test('playPrevious uses history before fallback', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      await service.playNext();
      api.commands.clear();

      final result = await service.playPrevious();

      expect(result.trackIdToPlay, 'b');
      expect(service.snapshot().currentTrackId, 'b');
      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'b',
        'c',
        'd',
      ]);
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'b'});
    });

    test('handleNaturalTrackEnd advances without explicit stop', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      api.commands.clear();

      final result = await service.handleNaturalTrackEnd();

      expect(result.trackIdToPlay, 'c');
      expect(service.snapshot().currentTrackId, 'c');
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'c'});
    });

    test('playNext loops queue in repeat all mode on last track', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      await service.playNext();
      await service.playNext();
      api.commands.clear();

      final result = await service.playNext(repeatMode: 'all');

      expect(result.trackIdToPlay, 'b');
      expect(result.queueChanged, isTrue);
      expect(service.snapshot().currentTrackId, 'b');
      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'b',
        'c',
        'd',
      ]);
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'b'});
    });

    test('playLibraryTrack shuffles upcoming queue when shuffle is enabled', () async {
      final result = await service.playLibraryTrack(
        const TrackItem(id: 'b', title: 'B'),
        shuffleEnabled: true,
      );

      expect(result.trackIdToPlay, 'b');
      expect(service.snapshot().currentTrackId, 'b');
      expect(service.snapshot().items.map((item) => item.trackId).toSet(), <String>{
        'b',
        'c',
        'd',
      });
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'b'});
    });

    test('handleNaturalTrackEnd repeats current track in repeat one mode', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      api.commands.clear();

      final result = await service.handleNaturalTrackEnd(repeatMode: 'one');

      expect(result.trackIdToPlay, 'b');
      expect(result.queueChanged, isFalse);
      expect(service.snapshot().currentTrackId, 'b');
      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'b',
        'c',
        'd',
      ]);
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'b'});
    });

    test('handleNaturalTrackEnd loops queue in repeat all mode on last track', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      await service.playNext();
      await service.playNext();
      api.commands.clear();

      final result = await service.handleNaturalTrackEnd(repeatMode: 'all');

      expect(result.trackIdToPlay, 'b');
      expect(result.queueChanged, isTrue);
      expect(service.snapshot().currentTrackId, 'b');
      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'b',
        'c',
        'd',
      ]);
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'b'});
    });

    test(
      'handleNaturalTrackEnd on last queue item sends stop command',
      () async {
        await service.playLibraryTrack(const TrackItem(id: 'd', title: 'D'));
        api.commands.clear();

        final result = await service.handleNaturalTrackEnd();

        expect(result.trackIdToPlay, isNull);
        expect(result.shouldStopPlayback, isTrue);
        expect(service.snapshot().isEmpty, isTrue);
        expect(api.commands.single.endpoint, '/api/stop');
        expect(api.commands.single.body, isNull);
      },
    );

    test(
      'removeQueueEntry stops playback when current last item is removed',
      () async {
        await service.playLibraryTrack(const TrackItem(id: 'd', title: 'D'));
        api.commands.clear();
        final currentEntryId = service.snapshot().currentEntryId!;

        final result = await service.removeQueueEntry(currentEntryId);

        expect(result.shouldStopPlayback, isTrue);
        expect(service.snapshot().isEmpty, isTrue);
        expect(api.commands.single.endpoint, '/api/stop');
        expect(api.commands.single.body, isNull);
      },
    );

    test('clearQueue keeps current track and does not send stop command', () async {
      await service.playLibraryTrack(const TrackItem(id: 'b', title: 'B'));
      api.commands.clear();

      await service.clearQueue();

      expect(service.snapshot().items.map((item) => item.trackId), <String>[
        'b',
      ]);
      expect(service.snapshot().currentTrackId, 'b');
      expect(api.commands, isEmpty);
    });

    test('hydrateQueueFromCurrentTrack bootstraps queue only once', () {
      service.hydrateQueueFromCurrentTrack('c');
      final firstSnapshot = service.snapshot();

      service.hydrateQueueFromCurrentTrack('a');
      final secondSnapshot = service.snapshot();

      expect(firstSnapshot.items.map((item) => item.trackId), <String>[
        'c',
        'd',
      ]);
      expect(secondSnapshot.items.map((item) => item.trackId), <String>[
        'c',
        'd',
      ]);
    });
  });
}
