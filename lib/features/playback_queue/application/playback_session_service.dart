import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class PlaybackSessionService {
  PlaybackSessionService({
    required MusicApi api,
    required PlaybackQueueService queueService,
  }) : _api = api,
       _queueService = queueService;

  final MusicApi _api;
  final PlaybackQueueService _queueService;

  void setLibrary(List<TrackItem> library) {
    _queueService.setLibrary(library);
  }

  PlaybackQueueSnapshot snapshot() => _queueService.snapshot();

  void hydrateQueueFromCurrentTrack(String? trackId) {
    if (trackId == null || trackId.isEmpty || !snapshot().isEmpty) {
      return;
    }
    _queueService.rebuildFromLibraryClick(trackId);
  }

  Future<QueueCommandResult> playLibraryTrack(
    TrackItem track, {
    bool shuffleEnabled = false,
  }) async {
    final result = _queueService.rebuildFromLibraryClick(track.id);
    if (shuffleEnabled) {
      _queueService.shuffleUpcoming();
    }
    return _executePlaybackResult(result);
  }

  Future<QueueCommandResult> playQueueOrBootstrapDefault({
    bool shuffleEnabled = false,
  }) async {
    final result = _queueService.playOrBootstrapDefault();
    if (shuffleEnabled) {
      _queueService.shuffleUpcoming();
    }
    return _executePlaybackResult(result);
  }

  Future<QueueCommandResult> playNext({
    String repeatMode = 'off',
  }) async {
    final currentSnapshot = snapshot();
    if (repeatMode == 'all' &&
        currentSnapshot.currentTrackId != null &&
        !currentSnapshot.canGoNext) {
      final result = _queueService.restartCycleFromHistory();
      return _executePlaybackResult(result);
    }

    final result = _queueService.advanceNext();
    return _executePlaybackResult(result);
  }

  Future<QueueCommandResult> handleNaturalTrackEnd({
    String repeatMode = 'off',
  }) async {
    final currentSnapshot = snapshot();
    if (repeatMode == 'one') {
      final currentTrackId = currentSnapshot.currentTrackId;
      if (currentTrackId != null) {
        final result = QueueCommandResult(
          queueChanged: false,
          shouldStopPlayback: false,
          trackIdToPlay: currentTrackId,
        );
        return _executePlaybackResult(result);
      }
    }

    if (repeatMode == 'all' &&
        currentSnapshot.currentTrackId != null &&
        !currentSnapshot.canGoNext) {
      final result = _queueService.restartCycleFromHistory();
      return _executePlaybackResult(result);
    }

    final result = _queueService.advanceNext();
    return _executePlaybackResult(result);
  }

  Future<QueueCommandResult> playPrevious() async {
    final result = _queueService.goBack();
    return _executePlaybackResult(result);
  }

  Future<void> clearQueue() async {
    _queueService.clearUpcomingKeepingCurrent();
  }

  bool shuffleUpcoming() => _queueService.shuffleUpcoming();

  void addTrackToQueueStart(String trackId) {
    _queueService.prependTrack(trackId);
  }

  void addTrackToQueueEnd(String trackId) {
    _queueService.appendTrack(trackId);
  }

  void addTrackAfterCurrent(String trackId) {
    _queueService.insertAfterCurrent(trackId);
  }

  Future<QueueCommandResult> removeQueueEntry(String entryId) async {
    final result = _queueService.removeEntry(entryId);
    return _executePlaybackResult(result);
  }

  void moveEntryBefore(String entryId, String targetEntryId) {
    _queueService.moveEntryBefore(entryId, targetEntryId);
  }

  void moveEntryAfter(String entryId, String targetEntryId) {
    _queueService.moveEntryAfter(entryId, targetEntryId);
  }

  Future<QueueCommandResult> _executePlaybackResult(
    QueueCommandResult result,
  ) async {
    if (result.trackIdToPlay != null) {
      await _api.command(
        '/api/play',
        body: <String, dynamic>{'track_id': result.trackIdToPlay},
      );
      return result;
    }

    if (result.shouldStopPlayback) {
      await _api.command('/api/stop');
    }

    return result;
  }
}
