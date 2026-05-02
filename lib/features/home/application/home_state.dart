import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/models/track_metadata.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

const Object unsetValue = Object();

class RemoteHomeState {
  const RemoteHomeState({
    this.tabIndex = 0,
    this.connection = const HomeConnectionState(),
    this.pairing = const HomePairingState(),
    this.playback = const HomePlaybackState(),
    this.library = const HomeLibraryState(),
    this.metadata = const HomeMetadataState(),
  });

  final int tabIndex;
  final HomeConnectionState connection;
  final HomePairingState pairing;
  final HomePlaybackState playback;
  final HomeLibraryState library;
  final HomeMetadataState metadata;

  RemoteHomeState copyWith({
    int? tabIndex,
    HomeConnectionState? connection,
    HomePairingState? pairing,
    HomePlaybackState? playback,
    HomeLibraryState? library,
    HomeMetadataState? metadata,
  }) => RemoteHomeState(
    tabIndex: tabIndex ?? this.tabIndex,
    connection: connection ?? this.connection,
    pairing: pairing ?? this.pairing,
    playback: playback ?? this.playback,
    library: library ?? this.library,
    metadata: metadata ?? this.metadata,
  );
}

class HomeConnectionState {
  const HomeConnectionState({
    this.busy = false,
    this.initializing = true,
    this.backgroundSyncing = false,
    this.commandBusy = false,
    this.serverHealthy = false,
    this.statusText = 'Disconnected',
    this.commandStatus = '',
    this.lastError = '',
  });

  final bool busy;
  final bool initializing;
  final bool backgroundSyncing;
  final bool commandBusy;
  final bool serverHealthy;
  final String statusText;
  final String commandStatus;
  final String lastError;

  HomeConnectionState copyWith({
    bool? busy,
    bool? initializing,
    bool? backgroundSyncing,
    bool? commandBusy,
    bool? serverHealthy,
    String? statusText,
    String? commandStatus,
    String? lastError,
  }) => HomeConnectionState(
    busy: busy ?? this.busy,
    initializing: initializing ?? this.initializing,
    backgroundSyncing: backgroundSyncing ?? this.backgroundSyncing,
    commandBusy: commandBusy ?? this.commandBusy,
    serverHealthy: serverHealthy ?? this.serverHealthy,
    statusText: statusText ?? this.statusText,
    commandStatus: commandStatus ?? this.commandStatus,
    lastError: lastError ?? this.lastError,
  );
}

class HomePairingState {
  const HomePairingState({
    this.discovering = false,
    this.pairing = false,
    this.deviceId = '',
    this.refreshToken = '',
    this.discoveredServers = const <DiscoveredServer>[],
  });

  final bool discovering;
  final bool pairing;
  final String deviceId;
  final String refreshToken;
  final List<DiscoveredServer> discoveredServers;

  HomePairingState copyWith({
    bool? discovering,
    bool? pairing,
    String? deviceId,
    String? refreshToken,
    List<DiscoveredServer>? discoveredServers,
  }) => HomePairingState(
    discovering: discovering ?? this.discovering,
    pairing: pairing ?? this.pairing,
    deviceId: deviceId ?? this.deviceId,
    refreshToken: refreshToken ?? this.refreshToken,
    discoveredServers: discoveredServers ?? this.discoveredServers,
  );
}

class HomePlaybackState {
  const HomePlaybackState({
    this.volume = 50,
    this.position = 0,
    this.duration = 0,
    this.stoppedSeekPosition,
    this.isSeeking = false,
    this.shuffle = false,
    this.repeatMode = 'off',
    this.currentTrack = 'No active track',
    this.currentTrackId,
    this.queueSnapshot = const PlaybackQueueSnapshot(
      items: <PlaybackQueueSnapshotItem>[],
      currentEntryId: null,
      currentTrackId: null,
      pendingLibraryBackTrackId: null,
      historyLength: 0,
      canGoNext: false,
      canGoPrev: false,
      isEmpty: true,
    ),
  });

  final double volume;
  final double position;
  final double duration;
  final double? stoppedSeekPosition;
  final bool isSeeking;
  final bool shuffle;
  final String repeatMode;
  final String currentTrack;
  final String? currentTrackId;
  final PlaybackQueueSnapshot queueSnapshot;

  HomePlaybackState copyWith({
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
  }) => HomePlaybackState(
    volume: volume ?? this.volume,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    stoppedSeekPosition: identical(stoppedSeekPosition, unsetValue)
        ? this.stoppedSeekPosition
        : stoppedSeekPosition as double?,
    isSeeking: isSeeking ?? this.isSeeking,
    shuffle: shuffle ?? this.shuffle,
    repeatMode: repeatMode ?? this.repeatMode,
    currentTrack: currentTrack ?? this.currentTrack,
    currentTrackId: identical(currentTrackId, unsetValue)
        ? this.currentTrackId
        : currentTrackId as String?,
    queueSnapshot: queueSnapshot ?? this.queueSnapshot,
  );
}

class HomeLibraryState {
  const HomeLibraryState({
    this.items = const <TrackItem>[],
    this.selectedTrackId,
    this.uploading = false,
    this.uploadProgress = 0,
  });

  final List<TrackItem> items;
  final String? selectedTrackId;
  final bool uploading;
  final double uploadProgress;

  HomeLibraryState copyWith({
    List<TrackItem>? items,
    Object? selectedTrackId = unsetValue,
    bool? uploading,
    double? uploadProgress,
  }) => HomeLibraryState(
    items: items ?? this.items,
    selectedTrackId: identical(selectedTrackId, unsetValue)
        ? this.selectedTrackId
        : selectedTrackId as String?,
    uploading: uploading ?? this.uploading,
    uploadProgress: uploadProgress ?? this.uploadProgress,
  );
}

class HomeMetadataState {
  const HomeMetadataState({
    this.loading = false,
    this.currentMetadata,
  });

  final bool loading;
  final TrackMetadata? currentMetadata;

  HomeMetadataState copyWith({
    bool? loading,
    Object? currentMetadata = unsetValue,
  }) => HomeMetadataState(
    loading: loading ?? this.loading,
    currentMetadata: identical(currentMetadata, unsetValue)
        ? this.currentMetadata
        : currentMetadata as TrackMetadata?,
  );
}
