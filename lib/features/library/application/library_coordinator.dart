import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/models/track_metadata.dart';
import 'package:music_remote_app/core/network/music_api.dart';

class LibraryRefreshResult {
  const LibraryRefreshResult({
    required this.library,
    required this.selectedTrackId,
  });

  final List<TrackItem> library;
  final String? selectedTrackId;
}

enum MetadataRefreshKind {
  noop,
  cleared,
  cacheHit,
  fetched,
}

class MetadataRefreshResult {
  const MetadataRefreshResult({
    required this.kind,
    required this.trackId,
    required this.metadata,
  });

  const MetadataRefreshResult.noop({
    required this.trackId,
    required this.metadata,
  }) : kind = MetadataRefreshKind.noop;

  const MetadataRefreshResult.cleared()
    : kind = MetadataRefreshKind.cleared,
      trackId = null,
      metadata = null;

  final MetadataRefreshKind kind;
  final String? trackId;
  final TrackMetadata? metadata;

  bool get shouldClear => kind == MetadataRefreshKind.cleared;
  bool get shouldFetch => kind == MetadataRefreshKind.fetched;
  bool get isNoop => kind == MetadataRefreshKind.noop;
}

class LibraryCoordinator {
  LibraryCoordinator({required MusicApi api}) : _api = api;

  final MusicApi _api;
  final Map<String, TrackMetadata> _metadataCache = <String, TrackMetadata>{};

  Future<LibraryRefreshResult> refreshLibrary({
    required String? selectedTrackId,
  }) async {
    final library = await _api.library(forceRescan: true);
    final nextSelectedTrackId = _resolveSelectedTrackId(
      library: library,
      selectedTrackId: selectedTrackId,
    );
    return LibraryRefreshResult(
      library: library,
      selectedTrackId: nextSelectedTrackId,
    );
  }

  TrackMetadata? cachedMetadata(String trackId) => _metadataCache[trackId];

  Future<MetadataRefreshResult> refreshMetadata({
    required String? currentTrackId,
    required String? selectedTrackId,
    required TrackMetadata? currentMetadata,
    required bool metadataLoading,
  }) async {
    final trackId = currentTrackId ?? selectedTrackId;
    if (trackId == null || trackId.isEmpty) {
      return const MetadataRefreshResult.cleared();
    }

    final cached = cachedMetadata(trackId);
    if (cached != null) {
      if (currentMetadata?.trackId == cached.trackId && !metadataLoading) {
        return MetadataRefreshResult.noop(
          trackId: trackId,
          metadata: currentMetadata,
        );
      }
      return MetadataRefreshResult(
        kind: MetadataRefreshKind.cacheHit,
        trackId: trackId,
        metadata: cached,
      );
    }

    final fetched = await _fetchAndCacheMetadata(trackId);
    return MetadataRefreshResult(
      kind: MetadataRefreshKind.fetched,
      trackId: trackId,
      metadata: fetched,
    );
  }

  Future<TrackMetadata> _fetchAndCacheMetadata(String trackId) async {
    final raw = await _api.metadata(trackId);
    final parsed = TrackMetadata.fromJson(raw);
    _metadataCache[trackId] = parsed;
    return parsed;
  }

  Future<void> uploadTrack(
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    await _api.uploadFile(
      path,
      onProgress: (sentBytes, totalBytes) {
        final progress = totalBytes <= 0
            ? 0.0
            : (sentBytes / totalBytes).clamp(0.0, 1.0);
        onProgress?.call(progress);
      },
    );
  }

  String resolveTrackTitle(String trackId, List<TrackItem> library) {
    for (final track in library) {
      if (track.id == trackId) {
        return track.title;
      }
    }
    return trackId;
  }

  void clearCache() {
    _metadataCache.clear();
  }

  static String? _resolveSelectedTrackId({
    required List<TrackItem> library,
    required String? selectedTrackId,
  }) {
    if (library.isEmpty) {
      return null;
    }
    if (selectedTrackId != null &&
        library.any((track) => track.id == selectedTrackId)) {
      return selectedTrackId;
    }
    return library.first.id;
  }
}
