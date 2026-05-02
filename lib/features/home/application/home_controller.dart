import 'package:flutter/foundation.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/features/home/application/home_state.dart';
import 'package:music_remote_app/features/library/application/library_coordinator.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';
import 'package:music_remote_app/features/playback_queue/application/playback_session_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class ApplyRemoteStateResult {
  const ApplyRemoteStateResult({
    required this.changed,
    required this.trackChanged,
    required this.shouldSyncSystemVolume,
  });

  const ApplyRemoteStateResult.noop()
    : changed = false,
      trackChanged = false,
      shouldSyncSystemVolume = false;

  final bool changed;
  final bool trackChanged;
  final bool shouldSyncSystemVolume;
}

class HomeController extends ChangeNotifier {
  HomeController({
    RemoteHomeState initialState = const RemoteHomeState(),
    PlaybackSessionService? playbackSession,
  }) : _state = initialState,
       _playbackSession = playbackSession;

  RemoteHomeState _state;
  final PlaybackSessionService? _playbackSession;

  RemoteHomeState get state => _state;

  void updateTabIndex(int value) {
    _state = _state.copyWith(tabIndex: value);
    notifyListeners();
  }

  void updateConnection({
    bool? busy,
    bool? initializing,
    bool? backgroundSyncing,
    bool? commandBusy,
    bool? serverHealthy,
    String? statusText,
    String? commandStatus,
    String? lastError,
  }) {
    _state = _state.copyWith(
      connection: _state.connection.copyWith(
        busy: busy,
        initializing: initializing,
        backgroundSyncing: backgroundSyncing,
        commandBusy: commandBusy,
        serverHealthy: serverHealthy,
        statusText: statusText,
        commandStatus: commandStatus,
        lastError: lastError,
      ),
    );
    notifyListeners();
  }

  void updatePairing({
    bool? discovering,
    bool? pairing,
    String? deviceId,
    String? refreshToken,
    List<DiscoveredServer>? discoveredServers,
  }) {
    _state = _state.copyWith(
      pairing: _state.pairing.copyWith(
        discovering: discovering,
        pairing: pairing,
        deviceId: deviceId,
        refreshToken: refreshToken,
        discoveredServers: discoveredServers == null
            ? null
            : List<DiscoveredServer>.unmodifiable(discoveredServers),
      ),
    );
    notifyListeners();
  }

  void updatePlayback({
    double? volume,
    double? position,
    double? duration,
    Object? stoppedSeekPosition = unsetValue,
    bool? isSeeking,
    bool? shuffle,
    String? repeatMode,
    String? currentTrack,
    Object? currentTrackId = unsetValue,
    PlaybackQueueSnapshot? queueSnapshot,
  }) {
    _state = _state.copyWith(
      playback: _state.playback.copyWith(
        volume: volume,
        position: position,
        duration: duration,
        stoppedSeekPosition: stoppedSeekPosition,
        isSeeking: isSeeking,
        shuffle: shuffle,
        repeatMode: repeatMode,
        currentTrack: currentTrack,
        currentTrackId: currentTrackId,
        queueSnapshot: queueSnapshot,
      ),
    );
    notifyListeners();
  }

  void updateLibrary({
    List<TrackItem>? items,
    Object? selectedTrackId = unsetValue,
    bool? uploading,
    double? uploadProgress,
  }) {
    _state = _state.copyWith(
      library: _state.library.copyWith(
        items: items == null ? null : List<TrackItem>.unmodifiable(items),
        selectedTrackId: selectedTrackId,
        uploading: uploading,
        uploadProgress: uploadProgress,
      ),
    );
    notifyListeners();
  }

  void updateMetadata({
    bool? loading,
    Object? currentMetadata = unsetValue,
  }) {
    _state = _state.copyWith(
      metadata: _state.metadata.copyWith(
        loading: loading,
        currentMetadata: currentMetadata,
      ),
    );
    notifyListeners();
  }

  void applyLibraryRefreshResult(LibraryRefreshResult result) {
    _state = _state.copyWith(
      library: _state.library.copyWith(
        items: List<TrackItem>.unmodifiable(result.library),
        selectedTrackId: result.selectedTrackId,
      ),
    );
    notifyListeners();
  }

  void startMetadataLoading() {
    if (_state.metadata.loading) {
      return;
    }
    _state = _state.copyWith(
      metadata: _state.metadata.copyWith(loading: true),
    );
    notifyListeners();
  }

  void applyMetadataRefreshResult(MetadataRefreshResult result) {
    if (result.isNoop) {
      return;
    }

    if (result.shouldClear) {
      _state = _state.copyWith(
        metadata: _state.metadata.copyWith(
          currentMetadata: null,
          loading: false,
        ),
      );
      notifyListeners();
      return;
    }

    final isStillActiveTrack =
        _state.playback.currentTrackId == result.trackId ||
        _state.library.selectedTrackId == result.trackId;
    _state = _state.copyWith(
      metadata: _state.metadata.copyWith(
        currentMetadata: isStillActiveTrack
            ? result.metadata
            : _state.metadata.currentMetadata,
        loading: false,
      ),
    );
    notifyListeners();
  }

  void clearMetadataLoading() {
    if (!_state.metadata.loading) {
      return;
    }
    _state = _state.copyWith(
      metadata: _state.metadata.copyWith(loading: false),
    );
    notifyListeners();
  }

  void startUpload() {
    _state = _state.copyWith(
      library: _state.library.copyWith(
        uploading: true,
        uploadProgress: 0,
      ),
    );
    notifyListeners();
  }

  void updateUploadProgress(double progress) {
    _state = _state.copyWith(
      library: _state.library.copyWith(
        uploadProgress: progress.clamp(0.0, 1.0),
      ),
    );
    notifyListeners();
  }

  void finishUpload() {
    _state = _state.copyWith(
      library: _state.library.copyWith(uploading: false),
    );
    notifyListeners();
  }

  void syncQueueState(PlaybackQueueSnapshot queueSnapshot) {
    final queueTrackId = queueSnapshot.currentTrackId;
    _state = _state.copyWith(
      playback: _state.playback.copyWith(queueSnapshot: queueSnapshot),
      library: queueTrackId != null && queueTrackId.isNotEmpty
          ? _state.library.copyWith(selectedTrackId: queueTrackId)
          : _state.library,
    );
    notifyListeners();
  }

  ApplyRemoteStateResult applyRemoteState(
    Map<String, dynamic> state, {
    required bool systemVolumeSupported,
    required String Function(String trackId) resolveTrackTitle,
  }) {
    final playback = _state.playback;
    final library = _state.library;
    final connection = _state.connection;

    final volumeRaw = state['volume'];
    final shuffleRaw = state['shuffle'];
    final repeatRaw = state['repeat_mode'];
    final statusRaw = state['status'] ?? state['state'];
    final trackRaw = state['current_track'] ?? state['track'];
    final currentTrackId = state['current_track_id']?.toString();
    final positionRaw = state['position'];
    final durationRaw = state['duration'];

    var trackTitle = 'No active track';
    if (trackRaw is Map<String, dynamic>) {
      trackTitle = _pickTrackTitle(trackRaw);
    } else if (trackRaw != null) {
      trackTitle = trackRaw.toString();
    }

    final nextVolume = (volumeRaw is num ? volumeRaw.toDouble() : playback.volume)
        .clamp(0, 100)
        .toDouble();
    final nextShuffle = shuffleRaw is bool ? shuffleRaw : playback.shuffle;
    final nextRepeatMode = _normalizeRepeatMode(
      repeatRaw?.toString() ?? playback.repeatMode,
    );
    final nextStatus = statusRaw?.toString() ?? connection.statusText;
    final nextTrackId = currentTrackId;
    final nextTrackTitle = nextTrackId != null && nextTrackId.isNotEmpty
        ? resolveTrackTitle(nextTrackId)
        : trackTitle;
    final nextDuration = durationRaw is num && durationRaw.toDouble() > 0
        ? durationRaw.toDouble()
        : playback.duration;
    final preserveStoppedSeek =
        !playback.isSeeking &&
        _isStoppedStatus(nextStatus) &&
        playback.stoppedSeekPosition != null;
    final nextPosition = preserveStoppedSeek
        ? playback.stoppedSeekPosition!
        : (!playback.isSeeking && positionRaw is num
              ? positionRaw.toDouble()
              : playback.position);
    final trackChanged = playback.currentTrackId != nextTrackId;

    final changed =
        (nextVolume - playback.volume).abs() > 0.1 ||
        nextShuffle != playback.shuffle ||
        nextRepeatMode != playback.repeatMode ||
        nextStatus != connection.statusText ||
        nextTrackTitle != playback.currentTrack ||
        nextTrackId != playback.currentTrackId ||
        (nextDuration - playback.duration).abs() > 0.1 ||
        (!playback.isSeeking &&
            (nextPosition - playback.position).abs() > 0.1);

    if (!changed) {
      return const ApplyRemoteStateResult.noop();
    }

    final shouldSyncSystemVolume =
        systemVolumeSupported && (nextVolume - playback.volume).abs() > 0.1;

    _state = _state.copyWith(
      connection: connection.copyWith(statusText: nextStatus),
      playback: playback.copyWith(
        volume: nextVolume,
        shuffle: nextShuffle,
        repeatMode: nextRepeatMode,
        currentTrack: nextTrackTitle,
        currentTrackId: nextTrackId,
        duration: nextDuration,
        position: playback.isSeeking ? playback.position : nextPosition,
        stoppedSeekPosition: _isStoppedStatus(nextStatus)
            ? playback.stoppedSeekPosition
            : null,
      ),
      library: nextTrackId != null && nextTrackId.isNotEmpty
          ? library.copyWith(selectedTrackId: nextTrackId)
          : library,
    );
    notifyListeners();

    return ApplyRemoteStateResult(
      changed: true,
      trackChanged: trackChanged,
      shouldSyncSystemVolume: shouldSyncSystemVolume,
    );
  }

  void resetAfterDisconnect() {
    _state = RemoteHomeState(
      connection: const HomeConnectionState(
        initializing: false,
        commandStatus: 'Session revoked',
      ),
      pairing: _state.pairing.copyWith(
        refreshToken: '',
      ),
    );
    notifyListeners();
  }

  Future<void> playTrack(TrackItem track) async {
    await _runQueueAction(
      () async {
        updatePlayback(stoppedSeekPosition: null);
        await _requirePlaybackSession().playLibraryTrack(
          track,
          shuffleEnabled: _state.playback.shuffle,
        );
        updateLibrary(selectedTrackId: track.id);
      },
      inProgressMessage: 'Starting playback...',
    );
  }

  Future<void> playCurrentQueueTrack({
    required Future<void> Function(double position) seekPlaybackPosition,
  }) async {
    if (_state.library.items.isEmpty && _state.playback.queueSnapshot.isEmpty) {
      updateConnection(commandStatus: 'No tracks loaded yet');
      return;
    }

    final startPosition = _isStoppedStatus(_state.connection.statusText)
        ? _state.playback.stoppedSeekPosition
        : null;

    await _runQueueAction(
      () async {
        await _requirePlaybackSession().playQueueOrBootstrapDefault(
          shuffleEnabled: _state.playback.shuffle,
        );
        if (startPosition != null && startPosition > 0) {
          await seekPlaybackPosition(startPosition);
        }
      },
      inProgressMessage: 'Starting playback...',
    );
  }

  Future<void> playPreviousTrack() => _runQueueAction(
    () => _requirePlaybackSession().playPrevious(),
    inProgressMessage: 'Loading previous track...',
  );

  Future<void> playNextTrack() => _runQueueAction(
    () => _requirePlaybackSession().playNext(
      repeatMode: _state.playback.repeatMode,
    ),
    inProgressMessage: 'Loading next track...',
  );

  Future<void> handlePlaybackEnded() => _runQueueAction(
    () => _requirePlaybackSession().handleNaturalTrackEnd(
      repeatMode: _state.playback.repeatMode,
    ),
    inProgressMessage: 'Advancing queue...',
  );

  Future<void> clearQueue() async {
    updateConnection(
      commandBusy: true,
      commandStatus: 'Clearing queue...',
      lastError: '',
    );
    try {
      await _requirePlaybackSession().clearQueue();
      syncQueueState(_requirePlaybackSession().snapshot());
      updateConnection(commandStatus: 'Done');
    } catch (error) {
      updateConnection(lastError: error.toString(), commandStatus: 'Failed');
      rethrow;
    } finally {
      updateConnection(commandBusy: false);
    }
  }

  void addTrackToQueueStart(TrackItem track) {
    _requirePlaybackSession().addTrackToQueueStart(track.id);
    updateLibrary(selectedTrackId: track.id);
    syncQueueState(_requirePlaybackSession().snapshot());
    updateConnection(commandStatus: 'Added to queue start');
  }

  void addTrackToQueueEnd(TrackItem track) {
    _requirePlaybackSession().addTrackToQueueEnd(track.id);
    updateLibrary(selectedTrackId: track.id);
    syncQueueState(_requirePlaybackSession().snapshot());
    updateConnection(commandStatus: 'Added to queue end');
  }

  void addTrackAfterCurrent(TrackItem track) {
    _requirePlaybackSession().addTrackAfterCurrent(track.id);
    updateLibrary(selectedTrackId: track.id);
    syncQueueState(_requirePlaybackSession().snapshot());
    updateConnection(commandStatus: 'Added after current');
  }

  Future<void> removeQueueEntry(String entryId) => _runQueueAction(
    () => _requirePlaybackSession().removeQueueEntry(entryId),
    inProgressMessage: 'Removing from queue...',
  );

  void reorderQueueEntry(int oldIndex, int newIndex) {
    final items = _state.playback.queueSnapshot.items;
    if (items.length < 2 || oldIndex == newIndex) {
      return;
    }

    final adjustedNewIndex = oldIndex < newIndex ? newIndex - 1 : newIndex;
    if (adjustedNewIndex < 0 ||
        adjustedNewIndex >= items.length ||
        adjustedNewIndex == oldIndex) {
      return;
    }

    final movedItem = items[oldIndex];
    final targetItem = items[adjustedNewIndex];

    if (oldIndex < newIndex) {
      _requirePlaybackSession().moveEntryAfter(
        movedItem.entryId,
        targetItem.entryId,
      );
    } else {
      _requirePlaybackSession().moveEntryBefore(
        movedItem.entryId,
        targetItem.entryId,
      );
    }
    syncQueueState(_requirePlaybackSession().snapshot());
    updateConnection(commandStatus: 'Queue reordered');
  }

  Future<void> _runQueueAction(
    Future<void> Function() action, {
    required String inProgressMessage,
  }) async {
    updateConnection(
      commandBusy: true,
      commandStatus: inProgressMessage,
      lastError: '',
    );
    try {
      await action();
      syncQueueState(_requirePlaybackSession().snapshot());
      updateConnection(commandStatus: 'Done');
    } catch (error) {
      updateConnection(lastError: error.toString(), commandStatus: 'Failed');
      rethrow;
    } finally {
      updateConnection(commandBusy: false);
    }
  }

  PlaybackSessionService _requirePlaybackSession() {
    final playbackSession = _playbackSession;
    if (playbackSession == null) {
      throw StateError('PlaybackSessionService is not configured.');
    }
    return playbackSession;
  }

  static bool _isStoppedStatus(String value) => value.toLowerCase() == 'stopped';

  static String _normalizeRepeatMode(String value) {
    if (value == 'one' || value == 'all' || value == 'off') {
      return value;
    }
    return 'off';
  }

  static String _pickTrackTitle(Map<String, dynamic> source) {
    final title =
        source['title']?.toString() ??
        source['name']?.toString() ??
        source['filename']?.toString() ??
        source['path']?.toString();
    if (title != null && title.trim().isNotEmpty) {
      return title;
    }
    return source['id']?.toString() ?? 'Unknown track';
  }
}
