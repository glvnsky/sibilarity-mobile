import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/library/application/library_coordinator.dart';

class _FakeMusicApi extends MusicApi {
  List<TrackItem> libraryResult = const <TrackItem>[];
  Map<String, dynamic> metadataResult = const <String, dynamic>{};
  bool forceRescanValue = false;
  String? metadataTrackId;
  String? uploadPath;
  void Function(int sentBytes, int totalBytes)? uploadProgressCallback;

  @override
  Future<List<TrackItem>> library({bool forceRescan = false}) async {
    forceRescanValue = forceRescan;
    return libraryResult;
  }

  @override
  Future<Map<String, dynamic>> metadata(String trackId) async {
    metadataTrackId = trackId;
    return metadataResult;
  }

  @override
  Future<void> uploadFile(
    String path, {
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    uploadPath = path;
    uploadProgressCallback = onProgress;
  }
}

void main() {
  group('LibraryCoordinator', () {
    test('refreshLibrary forces rescan and keeps selected track when present', () async {
      final api = _FakeMusicApi()
        ..libraryResult = const <TrackItem>[
          TrackItem(id: '1', title: 'Track 1'),
          TrackItem(id: '2', title: 'Track 2'),
        ];
      final coordinator = LibraryCoordinator(api: api);

      final result = await coordinator.refreshLibrary(selectedTrackId: '2');

      expect(api.forceRescanValue, isTrue);
      expect(result.library, hasLength(2));
      expect(result.library.first.title, 'Track 1');
      expect(result.selectedTrackId, '2');
    });

    test('refreshLibrary falls back to first track when selection is missing', () async {
      final api = _FakeMusicApi()
        ..libraryResult = const <TrackItem>[
          TrackItem(id: '1', title: 'Track 1'),
          TrackItem(id: '2', title: 'Track 2'),
        ];
      final coordinator = LibraryCoordinator(api: api);

      final result = await coordinator.refreshLibrary(
        selectedTrackId: 'missing',
      );

      expect(result.selectedTrackId, '1');
    });

    test('refreshMetadata caches fetched metadata', () async {
      final api = _FakeMusicApi()
        ..metadataResult = const <String, dynamic>{
          'track_id': 'abc',
          'source': 'taglib',
          'found': true,
          'title': 'Song A',
        };
      final coordinator = LibraryCoordinator(api: api);

      final result = await coordinator.refreshMetadata(
        currentTrackId: 'abc',
        selectedTrackId: null,
        currentMetadata: null,
        metadataLoading: false,
      );

      expect(api.metadataTrackId, 'abc');
      expect(result.kind, MetadataRefreshKind.fetched);
      expect(result.metadata?.title, 'Song A');
      expect(coordinator.cachedMetadata('abc')?.title, 'Song A');

      coordinator.clearCache();

      expect(coordinator.cachedMetadata('abc'), isNull);
    });

    test('refreshMetadata returns cache hit without fetching again', () async {
      final api = _FakeMusicApi()
        ..metadataResult = const <String, dynamic>{
          'track_id': 'abc',
          'source': 'taglib',
          'found': true,
          'title': 'Song A',
        };
      final coordinator = LibraryCoordinator(api: api);

      await coordinator.refreshMetadata(
        currentTrackId: 'abc',
        selectedTrackId: null,
        currentMetadata: null,
        metadataLoading: false,
      );
      api.metadataTrackId = null;

      final result = await coordinator.refreshMetadata(
        currentTrackId: 'abc',
        selectedTrackId: null,
        currentMetadata: null,
        metadataLoading: false,
      );

      expect(api.metadataTrackId, isNull);
      expect(result.kind, MetadataRefreshKind.cacheHit);
      expect(result.metadata?.title, 'Song A');
    });

    test('refreshMetadata returns noop when cached metadata is already applied', () async {
      final api = _FakeMusicApi()
        ..metadataResult = const <String, dynamic>{
          'track_id': 'abc',
          'source': 'taglib',
          'found': true,
          'title': 'Song A',
        };
      final coordinator = LibraryCoordinator(api: api);

      final fetched = await coordinator.refreshMetadata(
        currentTrackId: 'abc',
        selectedTrackId: null,
        currentMetadata: null,
        metadataLoading: false,
      );

      final result = await coordinator.refreshMetadata(
        currentTrackId: 'abc',
        selectedTrackId: null,
        currentMetadata: fetched.metadata,
        metadataLoading: false,
      );

      expect(result.kind, MetadataRefreshKind.noop);
      expect(result.metadata?.title, 'Song A');
    });

    test('refreshMetadata clears metadata when no active track exists', () async {
      final coordinator = LibraryCoordinator(api: _FakeMusicApi());

      final result = await coordinator.refreshMetadata(
        currentTrackId: null,
        selectedTrackId: null,
        currentMetadata: null,
        metadataLoading: false,
      );

      expect(result.kind, MetadataRefreshKind.cleared);
      expect(result.shouldClear, isTrue);
    });

    test('uploadTrack forwards path and normalizes progress callback', () async {
      final api = _FakeMusicApi();
      final progresses = <double>[];
      final coordinator = LibraryCoordinator(api: api);

      await coordinator.uploadTrack(
        'C:\\music\\song.mp3',
        onProgress: progresses.add,
      );
      api.uploadProgressCallback?.call(25, 100);
      api.uploadProgressCallback?.call(100, 100);

      expect(api.uploadPath, 'C:\\music\\song.mp3');
      expect(progresses, <double>[0.25, 1.0]);
    });

    test('resolveTrackTitle uses library match or falls back to id', () {
      final coordinator = LibraryCoordinator(api: _FakeMusicApi());
      const library = <TrackItem>[
        TrackItem(id: '1', title: 'Track 1'),
      ];

      expect(coordinator.resolveTrackTitle('1', library), 'Track 1');
      expect(coordinator.resolveTrackTitle('missing', library), 'missing');
    });
  });
}
