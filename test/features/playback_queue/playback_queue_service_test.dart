import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_service.dart';

void main() {
  group('PlaybackQueueService', () {
    late PlaybackQueueService service;

    setUp(() {
      service = PlaybackQueueService()
        ..setLibrary(const <TrackItem>[
          TrackItem(id: 'a', title: 'A'),
          TrackItem(id: 'b', title: 'B'),
          TrackItem(id: 'c', title: 'C'),
          TrackItem(id: 'd', title: 'D'),
          TrackItem(id: 'e', title: 'E'),
        ]);
    });

    test('rebuilds queue from clicked middle library track', () {
      final result = service.rebuildFromLibraryClick('c');
      final snapshot = service.snapshot();

      expect(result.trackIdToPlay, 'c');
      expect(snapshot.currentTrackId, 'c');
      expect(snapshot.pendingLibraryBackTrackId, 'b');
      expect(snapshot.items.map((item) => item.trackId), <String>[
        'c',
        'd',
        'e',
      ]);
    });

    test('next removes current and advances to next track', () {
      service.rebuildFromLibraryClick('c');

      final result = service.advanceNext();
      final snapshot = service.snapshot();

      expect(result.trackIdToPlay, 'd');
      expect(snapshot.currentTrackId, 'd');
      expect(snapshot.historyLength, 1);
      expect(snapshot.items.map((item) => item.trackId), <String>['d', 'e']);
    });

    test('back uses history before queue links', () {
      service
        ..rebuildFromLibraryClick('c')
        ..advanceNext();

      final result = service.goBack();
      final snapshot = service.snapshot();

      expect(result.trackIdToPlay, 'c');
      expect(snapshot.currentTrackId, 'c');
      expect(snapshot.items.map((item) => item.trackId), <String>[
        'c',
        'd',
        'e',
      ]);
      expect(snapshot.historyLength, 0);
    });

    test('back after fresh rebuild uses previous library item fallback', () {
      service.rebuildFromLibraryClick('c');

      final result = service.goBack();
      final snapshot = service.snapshot();

      expect(result.trackIdToPlay, 'b');
      expect(snapshot.currentTrackId, 'b');
      expect(snapshot.pendingLibraryBackTrackId, 'a');
      expect(snapshot.items.map((item) => item.trackId), <String>[
        'b',
        'c',
        'd',
        'e',
      ]);
    });

    test('back from first library item does nothing', () {
      service.rebuildFromLibraryClick('a');

      final result = service.goBack();
      final snapshot = service.snapshot();

      expect(result.trackIdToPlay, isNull);
      expect(snapshot.currentTrackId, 'a');
      expect(snapshot.canGoPrev, isFalse);
    });

    test('append duplicate tracks preserves separate queue entries', () {
      service
        ..appendTrack('b')
        ..appendTrack('b');

      final snapshot = service.snapshot();

      expect(snapshot.items.map((item) => item.trackId), <String>['b', 'b']);
      expect(snapshot.items.first.entryId, isNot(snapshot.items.last.entryId));
    });

    test('prepend and insert after current keep current track stable', () {
      service
        ..rebuildFromLibraryClick('c')
        ..prependTrack('a')
        ..insertAfterCurrent('b');

      final snapshot = service.snapshot();

      expect(snapshot.currentTrackId, 'c');
      expect(snapshot.items.map((item) => item.trackId), <String>[
        'a',
        'c',
        'b',
        'd',
        'e',
      ]);
    });

    test('remove current prefers next track and keeps earlier items', () {
      service
        ..rebuildFromLibraryClick('c')
        ..prependTrack('a');
      final currentEntryId = service.snapshot().currentEntryId!;

      final result = service.removeEntry(currentEntryId);
      final snapshot = service.snapshot();

      expect(result.trackIdToPlay, 'd');
      expect(snapshot.currentTrackId, 'd');
      expect(snapshot.items.map((item) => item.trackId), <String>[
        'a',
        'd',
        'e',
      ]);
    });

    test('clear removes queue and history', () {
      service
        ..rebuildFromLibraryClick('c')
        ..advanceNext()
        ..clear();
      final snapshot = service.snapshot();

      expect(snapshot.items, isEmpty);
      expect(snapshot.currentTrackId, isNull);
      expect(snapshot.historyLength, 0);
      expect(snapshot.isEmpty, isTrue);
    });

    test('move entry rewires list order', () {
      service
        ..rebuildFromLibraryClick('c')
        ..appendTrack('a');

      final snapshotBefore = service.snapshot();
      final movedEntryId = snapshotBefore.items.last.entryId;
      final targetEntryId = snapshotBefore.items.first.entryId;

      service.moveEntryBefore(movedEntryId, targetEntryId);
      final snapshotAfter = service.snapshot();

      expect(snapshotAfter.items.map((item) => item.trackId), <String>[
        'a',
        'c',
        'd',
        'e',
      ]);
      expect(snapshotAfter.currentTrackId, 'c');
    });

    test(
      'playOrBootstrapDefault picks first library item when queue is empty',
      () {
        final result = service.playOrBootstrapDefault();
        final snapshot = service.snapshot();

        expect(result.trackIdToPlay, 'a');
        expect(snapshot.currentTrackId, 'a');
        expect(snapshot.items.map((item) => item.trackId), <String>[
          'a',
          'b',
          'c',
          'd',
          'e',
        ]);
      },
    );
  });
}
