import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/models/track_metadata.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/home/application/home_controller.dart';
import 'package:music_remote_app/features/home/application/home_state.dart';
import 'package:music_remote_app/features/home/application/session_retry_coordinator.dart';
import 'package:music_remote_app/features/home/presentation/tabs/connect_tab.dart';
import 'package:music_remote_app/features/home/presentation/tabs/library_tab.dart';
import 'package:music_remote_app/features/home/presentation/tabs/player_tab.dart';
import 'package:music_remote_app/features/home/presentation/widgets/library_card.dart';
import 'package:music_remote_app/features/library/application/library_coordinator.dart';
import 'package:music_remote_app/features/pairing/application/pairing_coordinator.dart';
import 'package:music_remote_app/features/pairing/data/pairing_discovery_service.dart';
import 'package:music_remote_app/features/pairing/data/session_config_repository.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';
import 'package:music_remote_app/features/pairing/domain/models/session_config.dart';
import 'package:music_remote_app/features/playback/application/playback_realtime_coordinator.dart';
import 'package:music_remote_app/features/playback/application/playback_remote_coordinator.dart';
import 'package:music_remote_app/features/playback/application/playback_volume_sync_coordinator.dart';
import 'package:music_remote_app/features/playback_queue/application/playback_session_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

final _pairingDiscoveryService = PairingDiscoveryService();
final _sessionConfigRepository = SessionConfigRepository();

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _api = MusicApi();
  late final PlaybackRemoteCoordinator _playbackRemoteCoordinator =
      PlaybackRemoteCoordinator(api: _api);
  late final PairingCoordinator _pairingCoordinator = PairingCoordinator(
    api: _api,
    discoveryService: _pairingDiscoveryService,
    sessionConfigRepository: _sessionConfigRepository,
  );
  final _queueService = PlaybackQueueService();
  late final PlaybackSessionService _playbackSession = PlaybackSessionService(
    api: _api,
    queueService: _queueService,
  );
  late final HomeController _controller = HomeController(
    playbackSession: _playbackSession,
  );
  late final PlaybackRealtimeCoordinator _playbackRealtimeCoordinator =
      PlaybackRealtimeCoordinator(
        api: _api,
        onPlaybackEnded: _handlePlaybackEnded,
        onLibraryChanged: _refreshLibrary,
        onStatePayload: _applyState,
        onError: _handleRealtimeError,
        onPositionPoll: () => _refreshPosition(silent: true),
      );
  late final PlaybackVolumeSyncCoordinator _playbackVolumeSyncCoordinator =
      PlaybackVolumeSyncCoordinator(
        readCurrentVolume: () => _volume,
        applyLocalVolume: _applyLocalVolume,
        hasServerSession: _hasServerSession,
        sendRemoteVolume: _sendRemoteVolumeCommand,
      );
  late final SessionRetryCoordinator _sessionRetryCoordinator =
      SessionRetryCoordinator(
        refreshSession: _tryRefreshSession,
        markSessionExpired: _markSessionExpired,
        isUnauthorizedError: _isUnauthorizedError,
      );
  late final LibraryCoordinator _libraryCoordinator = LibraryCoordinator(
    api: _api,
  );

  RemoteHomeState get _state => _controller.state;
  HomeConnectionState get _connectionState => _controller.state.connection;
  HomePairingState get _pairingState => _controller.state.pairing;
  HomePlaybackState get _playbackState => _controller.state.playback;
  HomeLibraryState get _libraryState => _controller.state.library;
  HomeMetadataState get _metadataState => _controller.state.metadata;

  int get _tabIndex => _state.tabIndex;
  set _tabIndex(int value) => _controller.updateTabIndex(value);

  bool get _busy => _connectionState.busy;
  set _busy(bool value) => _controller.updateConnection(busy: value);

  bool get _initializing => _connectionState.initializing;
  set _initializing(bool value) => _controller.updateConnection(initializing: value);

  bool get _backgroundSyncing => _connectionState.backgroundSyncing;
  set _backgroundSyncing(bool value) =>
      _controller.updateConnection(backgroundSyncing: value);

  bool get _commandBusy => _connectionState.commandBusy;
  set _commandBusy(bool value) => _controller.updateConnection(commandBusy: value);

  bool get _serverHealthy => _connectionState.serverHealthy;
  set _serverHealthy(bool value) => _controller.updateConnection(serverHealthy: value);

  String get _statusText => _connectionState.statusText;
  set _statusText(String value) => _controller.updateConnection(statusText: value);

  String get _commandStatus => _connectionState.commandStatus;
  set _commandStatus(String value) => _controller.updateConnection(commandStatus: value);

  String get _lastError => _connectionState.lastError;
  set _lastError(String value) => _controller.updateConnection(lastError: value);

  bool get _discovering => _pairingState.discovering;
  set _discovering(bool value) => _controller.updatePairing(discovering: value);

  bool get _pairing => _pairingState.pairing;
  set _pairing(bool value) => _controller.updatePairing(pairing: value);

  String get _deviceId => _pairingState.deviceId;
  set _deviceId(String value) => _controller.updatePairing(deviceId: value);

  String get _refreshToken => _pairingState.refreshToken;
  set _refreshToken(String value) => _controller.updatePairing(refreshToken: value);

  List<DiscoveredServer> get _discoveredServers => _pairingState.discoveredServers;
  set _discoveredServers(List<DiscoveredServer> value) =>
      _controller.updatePairing(discoveredServers: value);

  double get _volume => _playbackState.volume;
  set _volume(double value) => _controller.updatePlayback(volume: value);

  double get _position => _playbackState.position;
  set _position(double value) => _controller.updatePlayback(position: value);

  double get _duration => _playbackState.duration;
  set _duration(double value) => _controller.updatePlayback(duration: value);

  double? get _stoppedSeekPosition => _playbackState.stoppedSeekPosition;
  set _stoppedSeekPosition(double? value) =>
      _controller.updatePlayback(stoppedSeekPosition: value);

  bool get _isSeeking => _playbackState.isSeeking;
  set _isSeeking(bool value) => _controller.updatePlayback(isSeeking: value);

  bool get _shuffle => _playbackState.shuffle;
  set _shuffle(bool value) => _controller.updatePlayback(shuffle: value);

  String get _repeatMode => _playbackState.repeatMode;
  set _repeatMode(String value) => _controller.updatePlayback(repeatMode: value);

  String get _currentTrack => _playbackState.currentTrack;

  String? get _currentTrackId => _playbackState.currentTrackId;

  PlaybackQueueSnapshot get _queueSnapshot => _playbackState.queueSnapshot;

  List<TrackItem> get _library => _libraryState.items;
  set _library(List<TrackItem> value) => _controller.updateLibrary(items: value);

  String? get _selectedTrackId => _libraryState.selectedTrackId;
  set _selectedTrackId(String? value) => _controller.updateLibrary(selectedTrackId: value);

  bool get _uploading => _libraryState.uploading;

  double get _uploadProgress => _libraryState.uploadProgress;

  bool get _metadataLoading => _metadataState.loading;

  TrackMetadata? get _currentMetadata => _metadataState.currentMetadata;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    unawaited(_playbackRealtimeCoordinator.disconnect());
    unawaited(_playbackVolumeSyncCoordinator.dispose());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _playbackVolumeSyncCoordinator.initialize();
    await _loadConfig();
    if (!mounted) {
      return;
    }
    // Let the first frame render before any network sync to reduce startup jank.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hasBase = _baseUrlController.text.trim().isNotEmpty;
      final hasToken = _normalizedToken(_tokenController.text).isNotEmpty;
      if (hasBase && hasToken) {
        // Silent reconnect: keep UI interactive while restoring the previous session.
        unawaited(_connectAndSync(showGlobalBusy: false));
      }
    });
  }

  bool _hasServerSession() =>
      _baseUrlController.text.trim().isNotEmpty &&
      _normalizedToken(_tokenController.text).isNotEmpty &&
      _serverHealthy;

  void _applyLocalVolume(double value) {
    if (!mounted) {
      return;
    }
    _volume = value;
  }

  void _onVolumeSliderChanged(double value) {
    _playbackVolumeSyncCoordinator.onSliderChanged(value);
  }

  Future<void> _loadConfig() async {
    final config = await _sessionConfigRepository.load();
    if (config.baseUrl.isNotEmpty) {
      _baseUrlController.text = config.baseUrl;
    }
    _tokenController.text = config.accessToken;
    _refreshToken = config.refreshToken;
    _deviceId = config.deviceId;
    _serverHealthy = false;
    _statusText = 'Ready for pairing';
    _initializing = false;
  }

  Future<void> _saveConfig() async {
    await _sessionConfigRepository.save(
      SessionConfig(
        baseUrl: _baseUrlController.text.trim(),
        accessToken: _normalizedToken(_tokenController.text),
        refreshToken: _refreshToken,
        deviceId: _deviceId,
      ),
    );
  }

  Future<void> _connectAndSync({bool showGlobalBusy = true}) async {
    if (showGlobalBusy) {
      _busy = true;
    } else {
      _backgroundSyncing = true;
    }
    _lastError = '';

    final baseUrl = _baseUrlController.text.trim();
    final token = _normalizedToken(_tokenController.text);
    if (baseUrl.isEmpty) {
      if (showGlobalBusy) {
        _busy = false;
      } else {
        _backgroundSyncing = false;
      }
      _serverHealthy = false;
      _statusText = 'Server is not selected';
      _lastError = 'Use Discover and pick a server first.';
      return;
    }
    if (token.isEmpty) {
      if (showGlobalBusy) {
        _busy = false;
      } else {
        _backgroundSyncing = false;
      }
      _serverHealthy = false;
      _statusText = 'Device is not paired';
      _lastError = 'Tap "Pair & Connect" to authorize this device.';
      return;
    }

    try {
      final result = await _sessionRetryCoordinator
          .run<PlaybackConnectSyncResult>(
            action: () => _playbackRemoteCoordinator.connectAndSync(
              baseUrl: baseUrl,
              accessToken: token,
            ),
            retryAction: () => _playbackRemoteCoordinator.connectAndSync(
              baseUrl: _baseUrlController.text.trim(),
              accessToken: _normalizedToken(_tokenController.text),
            ),
          );
      if (result == null) {
        return;
      }
      final systemVolume = _playbackVolumeSyncCoordinator.isSupported
          ? _volume
          : null;
      final effectiveState = Map<String, dynamic>.from(result.state);
      if (systemVolume != null) {
        effectiveState['volume'] = systemVolume;
      }
      final libraryData = result.library;

      _playbackSession
        ..setLibrary(libraryData)
        ..hydrateQueueFromCurrentTrack(
          result.state['current_track_id']?.toString(),
        );
      _serverHealthy = result.health;
      _library = libraryData;
      _syncQueueState();
      if (libraryData.isNotEmpty &&
          !libraryData.any((track) => track.id == _selectedTrackId)) {
        _selectedTrackId = libraryData.first.id;
      }
      _statusText = result.health ? 'Connected' : 'No response from /health';
      _applyState(effectiveState);

      await _playbackRealtimeCoordinator.connect();
      _playbackRealtimeCoordinator.startPositionPolling();
      if (systemVolume != null) {
        await _playbackVolumeSyncCoordinator.sendVolume(
          systemVolume,
          syncSystemVolume: false,
          showBusy: false,
        );
      }
      await _refreshPosition();
      // Metadata can load after UI is already ready.
      unawaited(_refreshCurrentMetadata());
      await _saveConfig();
    } catch (e) {
      _serverHealthy = false;
      _lastError = e.toString();
      _statusText = 'Connection failed';
    } finally {
      if (showGlobalBusy) {
        _busy = false;
      } else {
        _backgroundSyncing = false;
      }
    }
  }

  Future<void> _connectFromUi() => _connectAndSync();

  bool _isUnauthorizedError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('401') || message.contains('unauthorized');
  }

  Future<bool> _tryRefreshSession() async {
    final baseUrl = _baseUrlController.text.trim();
    final newToken = await _pairingCoordinator.refreshSession(
      baseUrl: baseUrl,
      accessToken: _normalizedToken(_tokenController.text),
      refreshToken: _refreshToken,
      deviceId: _deviceId,
    );
    if (newToken != null) {
      _tokenController.text = newToken;
      _api.configure(baseUrl: baseUrl, token: newToken);
      return true;
    }
    return false;
  }

  Future<void> _markSessionExpired({
    String message = 'Session expired. Pair again.',
  }) async {
    _tokenController.clear();
    _refreshToken = '';
    await _pairingCoordinator.clearExpiredSession();
    if (!mounted) {
      return;
    }
    _serverHealthy = false;
    _statusText = 'Not paired';
    _lastError = message;
    _commandStatus = 'Not paired';
    _commandBusy = false;
  }

  Future<void> _disconnect() async {
    final baseUrl = _baseUrlController.text.trim();
    final token = _normalizedToken(_tokenController.text);
    if (baseUrl.isNotEmpty && token.isNotEmpty) {
      try {
        await _playbackRemoteCoordinator.logout(
          baseUrl: baseUrl,
          accessToken: token,
        );
      } catch (e) {
        if (!_isUnauthorizedError(e) && mounted) {
          _lastError = 'Disconnect warning: $e';
        }
        // Local disconnect must still proceed even if server logout fails.
      }
    }

    await _playbackRealtimeCoordinator.disconnect();

    _tokenController.clear();
    _baseUrlController.clear();
    _refreshToken = '';
    await _sessionConfigRepository.clearConnection();

    if (!mounted) {
      return;
    }
    _controller.resetAfterDisconnect();
    _libraryCoordinator.clearCache();
    _queueService.clear();
    _syncQueueState();
  }

  Future<void> _discoverServers() async {
    if (_discovering) {
      return;
    }
    _discovering = true;
    _lastError = '';
    _discoveredServers = const <DiscoveredServer>[];

    try {
      final discovered = await _pairingCoordinator.discoverServers();

      if (!mounted) {
        return;
      }
      _discoveredServers = discovered;
      if (discovered.isNotEmpty) {
        // Discovery service returns best candidates first.
        _baseUrlController.text = discovered.first.baseUrl;
      } else {
        _lastError = 'No servers found in local network.';
      }
    } catch (e) {
      if (mounted) {
        _lastError = 'Discovery failed: $e';
      }
    } finally {
      _discovering = false;
    }
  }

  Future<void> _pairAndConnect() async {
    if (_pairing) {
      return;
    }
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      _lastError = 'Pick a discovered server first.';
      return;
    }
    _pairing = true;
    _lastError = '';
    try {
      final config = await _pairingCoordinator.pairAndPersistSession(
        baseUrl: baseUrl,
        currentToken: _tokenController.text.trim(),
        deviceId: _deviceId,
        requestPairingCode: _promptPairingCode,
      );
      if (config == null) {
        return;
      }
      _tokenController.text = config.accessToken;
      _refreshToken = config.refreshToken;
      await _connectAndSync();
    } catch (e) {
      if (mounted) {
        _lastError = 'Pairing failed: $e';
      }
    } finally {
      _pairing = false;
    }
  }

  Future<String?> _promptPairingCode(String pairingId) async {
    if (!mounted) {
      return null;
    }
    var codeValue = '';
    final shortPairingId = pairingId.length > 20
        ? '${pairingId.substring(0, 8)}...${pairingId.substring(pairingId.length - 8)}'
        : pairingId;
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter Pairing Code',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Pairing ID: $shortPairingId',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              const Text('Enter 6-digit code shown in server logs.'),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 6,
                onChanged: (value) {
                  codeValue = value.trim();
                },
                decoration: const InputDecoration(
                  labelText: 'Code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(codeValue),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (value == null || value.length != 6) {
      return null;
    }
    return value;
  }

  void _handleRealtimeError(String message) {
    if (!mounted) {
      return;
    }
    _lastError = message;
  }

  void _applyState(Map<String, dynamic> state) {
    final result = _controller.applyRemoteState(
      state,
      systemVolumeSupported: _playbackVolumeSyncCoordinator.isSupported,
      resolveTrackTitle: _resolveTrackTitle,
    );

    if (!result.changed) {
      return;
    }

    if (result.shouldSyncSystemVolume) {
      unawaited(_playbackVolumeSyncCoordinator.syncSystemVolumeFromRemote(_volume));
    }

    if (result.trackChanged) {
      // Metadata fetch is tied to track identity, not every state event.
      unawaited(_refreshCurrentMetadata());
    }
  }

  Future<void> _refreshState() async {
    try {
      final state = await _sessionRetryCoordinator.run<Map<String, dynamic>>(
        action: () => _playbackRemoteCoordinator.refreshState(
          baseUrl: _baseUrlController.text.trim(),
          accessToken: _normalizedToken(_tokenController.text),
        ),
      );
      if (state == null) {
        return;
      }
      _applyState(state);
    } catch (e) {
      _lastError = e.toString();
    }
  }

  Future<void> _refreshPosition({bool silent = false}) async {
    try {
      final position = await _sessionRetryCoordinator.run<Map<String, dynamic>>(
        action: () => _playbackRemoteCoordinator.refreshPosition(
          baseUrl: _baseUrlController.text.trim(),
          accessToken: _normalizedToken(_tokenController.text),
        ),
      );
      if (position == null) {
        return;
      }
      if (!mounted) {
        return;
      }
      final pos = position['position'];
      final dur = position['duration'];
      var shouldSetState = false;
      var nextPosition = _position;
      var nextDuration = _duration;

      if (!_isSeeking && pos is num) {
        final parsedPosition = pos.toDouble();
        final shouldPreserveStoppedSeek =
            _isStoppedStatus(_statusText) && _stoppedSeekPosition != null;
        if (!shouldPreserveStoppedSeek &&
            (parsedPosition - _position).abs() > 0.1) {
          nextPosition = parsedPosition;
          shouldSetState = true;
        }
      }
      if (dur is num && dur.toDouble() > 0) {
        final parsedDuration = dur.toDouble();
        if ((parsedDuration - _duration).abs() > 0.1) {
          nextDuration = parsedDuration;
          shouldSetState = true;
        }
      }
      if (!shouldSetState) {
        return;
      }
      _position = nextPosition;
      _duration = nextDuration;
    } catch (e) {
      if (!silent && mounted) {
        _lastError = e.toString();
      }
    }
  }

  Future<void> _refreshLibrary() async {
    try {
      final result = await _sessionRetryCoordinator.run<LibraryRefreshResult>(
        action: () => _libraryCoordinator.refreshLibrary(
          selectedTrackId: _selectedTrackId,
        ),
      );
      if (result == null) {
        return;
      }
      _controller.applyLibraryRefreshResult(result);
      _playbackSession
        ..setLibrary(result.library)
        ..hydrateQueueFromCurrentTrack(_currentTrackId);
      _syncQueueState();
      unawaited(_refreshCurrentMetadata());
    } catch (e) {
      _lastError = e.toString();
    }
  }

  Future<void> _refreshCurrentMetadata() async {
    final trackId = _currentTrackId ?? _selectedTrackId;
    if (trackId != null &&
        trackId.isNotEmpty &&
        _libraryCoordinator.cachedMetadata(trackId) == null &&
        !_metadataLoading) {
      _controller.startMetadataLoading();
    }
    try {
      final result = await _sessionRetryCoordinator.run<MetadataRefreshResult>(
        action: () => _libraryCoordinator.refreshMetadata(
          currentTrackId: _currentTrackId,
          selectedTrackId: _selectedTrackId,
          currentMetadata: _currentMetadata,
          metadataLoading: _metadataLoading,
        ),
      );
      if (result == null) {
        return;
      }
      if (!mounted) {
        return;
      }
      if (result.isNoop) {
        return;
      }
      _controller.applyMetadataRefreshResult(result);
    } catch (e) {
      if (!mounted) {
        return;
      }
      _controller.clearMetadataLoading();
    }
  }

  Future<void> _sendCommand(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    _commandBusy = true;
    _commandStatus = 'Sending command...';
    _lastError = '';
    try {
      final completed = await _sessionRetryCoordinator.run<bool>(
        action: () async {
          await _playbackRemoteCoordinator.sendCommand(
            baseUrl: _baseUrlController.text.trim(),
            accessToken: _normalizedToken(_tokenController.text),
            endpoint: endpoint,
            body: body,
          );
          return true;
        },
      );
      if (completed == null) {
        return;
      }
      await _refreshState();
      _commandStatus = 'Done';
    } catch (e) {
      _lastError = e.toString();
      _commandStatus = 'Failed';
    } finally {
      _commandBusy = false;
    }
  }

  Future<void> _sendRemoteVolumeCommand(
    double value, {
    required bool showBusy,
  }) async {
    if (!_hasServerSession()) {
      return;
    }

    if (showBusy) {
      _commandBusy = true;
      _commandStatus = 'Sending command...';
      _lastError = '';
    }
    try {
      final completed = await _sessionRetryCoordinator.run<bool>(
        action: () async {
          await _playbackRemoteCoordinator.sendCommand(
            baseUrl: _baseUrlController.text.trim(),
            accessToken: _normalizedToken(_tokenController.text),
            endpoint: '/api/volume',
            body: <String, dynamic>{'volume': value.round()},
          );
          return true;
        },
      );
      if (completed == null) {
        return;
      }
      if (showBusy) {
        _commandStatus = 'Done';
      }
    } catch (e) {
      if (mounted) {
        _lastError = e.toString();
        if (showBusy) {
          _commandStatus = 'Failed';
        }
      }
    } finally {
      if (showBusy && mounted) {
        _commandBusy = false;
      }
    }
  }

  Future<void> _setVolume(double value) async {
    await _playbackVolumeSyncCoordinator.commitSliderVolume(value);
  }

  Future<void> _seekTo(double value) async {
    if (_isStoppedStatus(_statusText)) {
      _isSeeking = false;
      _stoppedSeekPosition = value.clamp(0, _duration > 0 ? _duration : value);
      _position = _stoppedSeekPosition!;
      _commandStatus = 'Start position updated';
      _lastError = '';
      return;
    }
    _isSeeking = true;
    _position = value.clamp(0, _duration > 0 ? _duration : value);
    _commandBusy = true;
    _commandStatus = 'Seeking...';
    _lastError = '';
    try {
      final completed = await _sessionRetryCoordinator.run<bool>(
        action: () async {
          await _playbackRemoteCoordinator.seek(
            baseUrl: _baseUrlController.text.trim(),
            accessToken: _normalizedToken(_tokenController.text),
            position: _position,
          );
          return true;
        },
      );
      if (completed == null) {
        return;
      }
      await _refreshPosition();
      _commandStatus = 'Done';
    } catch (e) {
      _lastError = e.toString();
      _commandStatus = 'Failed';
    } finally {
      _isSeeking = false;
      _commandBusy = false;
    }
  }

  Future<void> _updateModes({bool? shuffle, String? repeatMode}) async {
    final payload = <String, dynamic>{
      'shuffle': shuffle ?? _shuffle,
      'repeat_mode': repeatMode ?? _repeatMode,
    };
    await _sendCommand('/api/modes', body: payload);
  }

  Future<void> _toggleShuffle() async {
    final nextValue = !_shuffle;
    _shuffle = nextValue;
    if (nextValue && _playbackSession.shuffleUpcoming()) {
      _syncQueueState();
      _commandStatus = 'Queue shuffled';
    }
    await _updateModes(shuffle: nextValue);
  }

  Future<void> _cycleRepeatMode() async {
    final nextMode = switch (_repeatMode) {
      'off' => 'one',
      'one' => 'all',
      _ => 'off',
    };
    _repeatMode = nextMode;
    await _updateModes(repeatMode: nextMode);
  }

  void _syncQueueState() {
    _controller.syncQueueState(_playbackSession.snapshot());
  }

  Future<void> _runControllerPlaybackAction(
    Future<void> Function() action,
  ) async {
    try {
      final completed = await _sessionRetryCoordinator.run<bool>(
        action: () async {
          await action();
          return true;
        },
      );
      if (completed == null) {
        return;
      }
      await _refreshState();
      unawaited(_refreshCurrentMetadata());
    } catch (e) {
      if (mounted) {
        _lastError = e.toString();
      }
    }
  }

  Future<void> _playTrack(TrackItem track) async {
    await _runControllerPlaybackAction(() => _controller.playTrack(track));
  }

  Future<void> _playCurrentQueueTrack() async {
    await _runControllerPlaybackAction(
      () => _controller.playCurrentQueueTrack(
        seekPlaybackPosition: (position) => _playbackRemoteCoordinator.seek(
          baseUrl: _baseUrlController.text.trim(),
          accessToken: _normalizedToken(_tokenController.text),
          position: position,
        ),
      ),
    );
  }

  Future<void> _playPreviousTrack() async {
    await _runControllerPlaybackAction(_controller.playPreviousTrack);
  }

  Future<void> _playNextTrack() async {
    await _runControllerPlaybackAction(_controller.playNextTrack);
  }

  Future<void> _handlePlaybackEnded() async {
    await _runControllerPlaybackAction(_controller.handlePlaybackEnded);
  }

  Future<void> _clearQueue() async {
    await _runControllerPlaybackAction(_controller.clearQueue);
  }

  void _addTrackToQueueStart(TrackItem track) {
    _controller.addTrackToQueueStart(track);
  }

  void _addTrackToQueueEnd(TrackItem track) {
    _controller.addTrackToQueueEnd(track);
  }

  void _addTrackAfterCurrent(TrackItem track) {
    _controller.addTrackAfterCurrent(track);
  }

  Future<void> _removeQueueEntry(String entryId) async {
    await _runControllerPlaybackAction(() => _controller.removeQueueEntry(entryId));
  }

  void _reorderQueueEntry(int oldIndex, int newIndex) {
    _controller.reorderQueueEntry(oldIndex, newIndex);
  }

  void _selectDiscoveredServer(String baseUrl) {
    setState(() {
      _baseUrlController.text = baseUrl;
    });
  }

  void _previewSeek(double value) {
    setState(() {
      _isSeeking = true;
      _position = value;
    });
  }

  Future<void> _uploadTrack() async {
    if (_uploading) {
      return;
    }
    final picked = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (picked == null || picked.files.single.path == null) {
      return;
    }

    _controller.startUpload();
    _lastError = '';

    try {
      final completed = await _sessionRetryCoordinator.run<bool>(
        action: () async {
          await _libraryCoordinator.uploadTrack(
            picked.files.single.path!,
            onProgress: (progress) {
          if (!mounted) {
            return;
          }
          _controller.updateUploadProgress(progress);
        },
      );
          return true;
        },
      );
      if (completed == null) {
        return;
      }
      await _refreshLibrary();
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _controller.finishUpload();
    }
  }

  bool _isStoppedStatus(String value) => value.toLowerCase() == 'stopped';

  String _normalizedToken(String raw) {
    final trimmed = raw.trim();
    return trimmed.replaceFirst(RegExp(r'#+$'), '');
  }

  String _resolveTrackTitle(String trackId) =>
      _libraryCoordinator.resolveTrackTitle(trackId, _library);

  String _formatDuration(double seconds) {
    final clamped = seconds.isFinite ? seconds.clamp(0, 864000).toInt() : 0;
    final duration = Duration(seconds: clamped);
    String two(int v) => v.toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:${two(duration.inMinutes.remainder(60))}:${two(duration.inSeconds.remainder(60))}';
    }
    return '${duration.inMinutes}:${two(duration.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Sibilarity Music Remote')),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => _tabIndex = index,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.link), label: 'Connect'),
          NavigationDestination(icon: Icon(Icons.equalizer), label: 'Player'),
          NavigationDestination(
            icon: Icon(Icons.library_music),
            label: 'Library',
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _connectFromUi,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_tabIndex == 0) ...[
                    ConnectTab(
                      serverHealthy: _serverHealthy,
                      statusText: _statusText,
                      selectedServer: _baseUrlController.text.trim(),
                      isPaired: _normalizedToken(_tokenController.text).isNotEmpty,
                      busy: _busy,
                      backgroundSyncing: _backgroundSyncing,
                      pairing: _pairing,
                      discovering: _discovering,
                      discoveredServers: _discoveredServers,
                      lastError: _lastError,
                      initializing: _initializing,
                      onDisconnect: _disconnect,
                      onPairAndConnect: _pairAndConnect,
                      onDiscoverServers: _discoverServers,
                      onRefreshState: _refreshState,
                      onSelectServer: _selectDiscoveredServer,
                    ),
                  ] else if (_tabIndex == 1) ...[
                    PlayerTab(
                      metadata: _currentMetadata,
                      metadataLoading: _metadataLoading,
                      currentTrack: _currentTrack,
                      statusText: _statusText,
                      position: _position,
                      duration: _duration,
                      volume: _volume,
                      isSeeking: _isSeeking,
                      commandBusy: _commandBusy,
                      commandStatus: _commandStatus,
                      queueSnapshot: _queueSnapshot,
                      shuffle: _shuffle,
                      repeatMode: _repeatMode,
                      formatDuration: _formatDuration,
                      resolveTrackTitle: _resolveTrackTitle,
                      onSeekPreviewChanged: _previewSeek,
                      onSeekTo: _seekTo,
                      onVolumeChanged: _onVolumeSliderChanged,
                      onVolumeCommitted: _setVolume,
                      onPrev: _playPreviousTrack,
                      onPlay: _playCurrentQueueTrack,
                      onPause: () => _sendCommand('/api/pause'),
                      onResume: () => _sendCommand('/api/resume'),
                      onNext: _playNextTrack,
                      onCycleRepeatMode: _cycleRepeatMode,
                      onToggleShuffle: _toggleShuffle,
                      onClearQueue: _clearQueue,
                      onRemoveQueueEntry: _removeQueueEntry,
                      onReorderQueueEntry: _reorderQueueEntry,
                    ),
                  ] else ...[
                    LibraryTab(
                      library: _library,
                      uploading: _uploading,
                      uploadProgress: _uploadProgress,
                      onRefreshLibrary: _refreshLibrary,
                      onUploadTrack: _uploadTrack,
                      onTrackTap: _playTrack,
                      onTrackAction: _handleLibraryTrackAction,
                    ),
                  ],
                ],
              ),
            ),
    ),
  );

  Future<void> _handleLibraryTrackAction(
    TrackItem track,
    LibraryTrackAction action,
  ) async {
    switch (action) {
      case LibraryTrackAction.addToQueueStart:
        _addTrackToQueueStart(track);
        return;
      case LibraryTrackAction.addAfterCurrent:
        _addTrackAfterCurrent(track);
        return;
      case LibraryTrackAction.addToQueueEnd:
        _addTrackToQueueEnd(track);
        return;
    }
  }

}
