import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/models/track_metadata.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/core/platform/android_system_volume.dart';
import 'package:music_remote_app/features/home/presentation/widgets/library_card.dart';
import 'package:music_remote_app/features/home/presentation/widgets/playback_queue_card.dart';
import 'package:music_remote_app/features/home/presentation/widgets/transport_card.dart';
import 'package:music_remote_app/features/pairing/data/pairing_discovery_service.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';
import 'package:music_remote_app/features/playback_queue/application/playback_session_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _pairingDiscoveryService = PairingDiscoveryService();

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _api = MusicApi();
  final _queueService = PlaybackQueueService();
  late final PlaybackSessionService _playbackSession = PlaybackSessionService(
    api: _api,
    queueService: _queueService,
  );

  int _tabIndex = 0;
  bool _busy = false;
  bool _initializing = true;
  bool _backgroundSyncing = false;
  bool _commandBusy = false;
  bool _serverHealthy = false;
  double _volume = 50;
  double _position = 0;
  double _duration = 0;
  double? _stoppedSeekPosition;
  bool _isSeeking = false;
  bool _shuffle = false;
  String _repeatMode = 'off';
  String _commandStatus = '';
  String _statusText = 'Disconnected';
  String _currentTrack = 'No active track';
  String? _currentTrackId;
  String? _selectedTrackId;
  String _lastError = '';
  bool _discovering = false;
  bool _pairing = false;
  String _deviceId = '';
  String _refreshToken = '';
  final List<DiscoveredServer> _discoveredServers = [];
  bool _uploading = false;
  double _uploadProgress = 0;
  bool _metadataLoading = false;
  TrackMetadata? _currentMetadata;
  final Map<String, TrackMetadata> _metadataCache = {};

  List<TrackItem> _library = const [];
  PlaybackQueueSnapshot _queueSnapshot = const PlaybackQueueSnapshot(
    items: <PlaybackQueueSnapshotItem>[],
    currentEntryId: null,
    currentTrackId: null,
    pendingLibraryBackTrackId: null,
    historyLength: 0,
    canGoNext: false,
    canGoPrev: false,
    isEmpty: true,
  );

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSubscription;
  StreamSubscription<double>? _systemVolumeSubscription;
  Timer? _positionTimer;
  Timer? _volumeSyncTimer;
  double? _pendingSystemVolume;
  double? _pendingSliderVolumeSync;
  bool _volumeSyncInFlight = false;

  static const double _systemVolumeTolerance = 5.0;
  static const Duration _volumeSyncDebounce = Duration(milliseconds: 75);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    _wsSubscription?.cancel();
    _systemVolumeSubscription?.cancel();
    _channel?.sink.close();
    _positionTimer?.cancel();
    _volumeSyncTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _initializeAndroidSystemVolumeSync();
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

  Future<void> _initializeAndroidSystemVolumeSync() async {
    if (!AndroidSystemVolume.instance.isSupported) {
      return;
    }

    final currentVolume =
        await AndroidSystemVolume.instance.getCurrentVolumePercent();
    if (!mounted) {
      return;
    }
    if (currentVolume != null) {
      setState(() {
        _volume = currentVolume;
      });
    }

    _systemVolumeSubscription = AndroidSystemVolume.instance.volumeChanges.listen(
      (value) => unawaited(_handleAndroidSystemVolumeChanged(value)),
    );
  }

  Future<void> _handleAndroidSystemVolumeChanged(double value) async {
    final nextVolume = value.clamp(0, 100).toDouble();
    final pending = _pendingSystemVolume;
    if (pending != null &&
        (nextVolume - pending).abs() <= _systemVolumeTolerance) {
      _pendingSystemVolume = null;
      if (mounted && (nextVolume - _volume).abs() > 0.1) {
        setState(() {
          _volume = nextVolume;
        });
      }
      return;
    }

    if (mounted && (nextVolume - _volume).abs() > 0.1) {
      setState(() {
        _volume = nextVolume;
      });
    }
    if (!_hasServerSession()) {
      return;
    }
    await _sendVolumeCommand(
      nextVolume,
      syncSystemVolume: false,
      showBusy: false,
    );
  }

  bool _hasServerSession() =>
      _baseUrlController.text.trim().isNotEmpty &&
      _normalizedToken(_tokenController.text).isNotEmpty &&
      _serverHealthy;

  Future<double?> _setAndroidSystemVolume(double value) async {
    if (!AndroidSystemVolume.instance.isSupported) {
      return null;
    }
    final nextVolume = value.clamp(0, 100).toDouble();
    _pendingSystemVolume = nextVolume;
    final applied =
        await AndroidSystemVolume.instance.setVolumePercent(nextVolume);
    if (applied != null) {
      _pendingSystemVolume = applied;
      if (mounted && (applied - _volume).abs() > 0.1) {
        setState(() {
          _volume = applied;
        });
      }
    }
    return applied;
  }

  void _onVolumeSliderChanged(double value) {
    final nextVolume = value.clamp(0, 100).toDouble();
    setState(() {
      _volume = nextVolume;
    });
    _pendingSliderVolumeSync = nextVolume;
    _volumeSyncTimer?.cancel();
    _volumeSyncTimer = Timer(
      _volumeSyncDebounce,
      () => unawaited(_flushPendingVolumeSync()),
    );
  }

  Future<void> _flushPendingVolumeSync() async {
    _volumeSyncTimer?.cancel();
    _volumeSyncTimer = null;
    final queuedVolume = _pendingSliderVolumeSync;
    if (queuedVolume == null) {
      return;
    }
    if (_volumeSyncInFlight) {
      return;
    }

    _pendingSliderVolumeSync = null;
    _volumeSyncInFlight = true;
    try {
      await _sendVolumeCommand(
        queuedVolume,
        syncSystemVolume: true,
        showBusy: false,
      );
    } finally {
      _volumeSyncInFlight = false;
      final nextQueued = _pendingSliderVolumeSync;
      if (nextQueued != null && (nextQueued - queuedVolume).abs() > 0.1) {
        unawaited(_flushPendingVolumeSync());
      }
    }
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString('base_url');
    final token = prefs.getString('api_token');
    final refresh = prefs.getString('refresh_token');
    final deviceId = prefs.getString('device_id');
    if (base != null && base.isNotEmpty) {
      _baseUrlController.text = base;
    }
    if (token != null) {
      _tokenController.text = token;
    }
    if (refresh != null) {
      _refreshToken = refresh;
    }
    if (deviceId != null && deviceId.isNotEmpty) {
      _deviceId = deviceId;
    } else {
      final randomPart = Random()
          .nextInt(0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0');
      _deviceId = 'mobile-${DateTime.now().millisecondsSinceEpoch}-$randomPart';
      await prefs.setString('device_id', _deviceId);
    }
    if (mounted) {
      setState(() {
        _serverHealthy = false;
        _statusText = 'Ready for pairing';
        _initializing = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base_url', _baseUrlController.text.trim());
    await prefs.setString('api_token', _normalizedToken(_tokenController.text));
    await prefs.setString('refresh_token', _refreshToken);
    await prefs.setString('device_id', _deviceId);
  }

  Future<void> _connectAndSync({bool showGlobalBusy = true}) async {
    setState(() {
      if (showGlobalBusy) {
        _busy = true;
      } else {
        _backgroundSyncing = true;
      }
      _lastError = '';
    });

    final baseUrl = _baseUrlController.text.trim();
    final token = _normalizedToken(_tokenController.text);
    if (baseUrl.isEmpty) {
      setState(() {
        if (showGlobalBusy) {
          _busy = false;
        } else {
          _backgroundSyncing = false;
        }
        _serverHealthy = false;
        _statusText = 'Server is not selected';
        _lastError = 'Use Discover and pick a server first.';
      });
      return;
    }
    if (token.isEmpty) {
      setState(() {
        if (showGlobalBusy) {
          _busy = false;
        } else {
          _backgroundSyncing = false;
        }
        _serverHealthy = false;
        _statusText = 'Device is not paired';
        _lastError = 'Tap "Pair & Connect" to authorize this device.';
      });
      return;
    }

    try {
      _api.configure(baseUrl: baseUrl, token: token);
      // Run independent startup requests in parallel.
      final (health, state, libraryData) = await (
        _api.health(),
        _api.state(),
        _api.library(),
      ).wait;
      final systemVolume =
          await AndroidSystemVolume.instance.getCurrentVolumePercent();
      final effectiveState = Map<String, dynamic>.from(state);
      if (systemVolume != null) {
        effectiveState['volume'] = systemVolume;
      }

      _playbackSession
        ..setLibrary(libraryData)
        ..hydrateQueueFromCurrentTrack(state['current_track_id']?.toString());
      setState(() {
        _serverHealthy = health;
        _library = libraryData;
        _syncQueueState();
        if (libraryData.isNotEmpty &&
            !libraryData.any((track) => track.id == _selectedTrackId)) {
          _selectedTrackId = libraryData.first.id;
        }
        _statusText = health ? 'Connected' : 'No response from /health';
      });
      _applyState(effectiveState);

      _connectWebSocket();
      _startPositionPolling();
      if (systemVolume != null) {
        await _sendVolumeCommand(
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
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _connectAndSync(showGlobalBusy: showGlobalBusy);
          return;
        }
        await _markSessionExpired();
        return;
      }
      setState(() {
        _serverHealthy = false;
        _lastError = e.toString();
        _statusText = 'Connection failed';
      });
    } finally {
      setState(() {
        if (showGlobalBusy) {
          _busy = false;
        } else {
          _backgroundSyncing = false;
        }
      });
    }
  }

  Future<void> _connectFromUi() => _connectAndSync();

  bool _isUnauthorizedError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('401') || message.contains('unauthorized');
  }

  Future<bool> _tryRefreshSession() async {
    if (_refreshToken.isEmpty) {
      return false;
    }
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      return false;
    }
    try {
      _api.configure(
        baseUrl: baseUrl,
        token: _normalizedToken(_tokenController.text),
      );
      final newToken = await _api.refreshAccessToken(_refreshToken);
      _tokenController.text = newToken;
      _api.configure(baseUrl: baseUrl, token: newToken);
      await _saveConfig();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markSessionExpired({
    String message = 'Session expired. Pair again.',
  }) async {
    _tokenController.clear();
    _refreshToken = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('api_token');
    await prefs.remove('refresh_token');
    if (!mounted) {
      return;
    }
    setState(() {
      _serverHealthy = false;
      _statusText = 'Not paired';
      _lastError = message;
      _commandStatus = 'Not paired';
      _commandBusy = false;
    });
  }

  Future<void> _disconnect() async {
    final baseUrl = _baseUrlController.text.trim();
    final token = _normalizedToken(_tokenController.text);
    if (baseUrl.isNotEmpty && token.isNotEmpty) {
      try {
        _api.configure(baseUrl: baseUrl, token: token);
        await _api.logout();
      } catch (e) {
        if (!_isUnauthorizedError(e) && mounted) {
          setState(() {
            _lastError = 'Disconnect warning: $e';
          });
        }
        // Local disconnect must still proceed even if server logout fails.
      }
    }

    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await _channel?.sink.close();
    _channel = null;
    _positionTimer?.cancel();
    _positionTimer = null;

    _tokenController.clear();
    _baseUrlController.clear();
    _refreshToken = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('base_url');
    await prefs.remove('api_token');
    await prefs.remove('refresh_token');

    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _backgroundSyncing = false;
      _commandBusy = false;
      _discovering = false;
      _pairing = false;
      _serverHealthy = false;
      _statusText = 'Disconnected';
      _commandStatus = 'Session revoked';
      _lastError = '';
      _tabIndex = 0;
      _currentTrack = 'No active track';
      _currentTrackId = null;
      _selectedTrackId = null;
      _volume = 50;
      _position = 0;
      _duration = 0;
      _stoppedSeekPosition = null;
      _isSeeking = false;
      _shuffle = false;
      _repeatMode = 'off';
      _uploading = false;
      _uploadProgress = 0;
      _metadataLoading = false;
      _currentMetadata = null;
      _metadataCache.clear();
      _library = const [];
      _queueService.clear();
      _syncQueueState();
      _discoveredServers.clear();
    });
  }

  void _connectWebSocket() {
    _wsSubscription?.cancel();
    _channel?.sink.close();

    try {
      _channel = _api.openSocket();
      _wsSubscription = _channel!.stream.listen(
        (message) {
          final decoded = _tryDecode(message);
          // WebSocket payloads are expected to be state-like JSON events.
          if (decoded is Map<String, dynamic>) {
            _handleWsEvent(decoded);
          }
        },
        onError: (Object error) {
          setState(() {
            _lastError =
                'WebSocket unavailable. REST controls still work. Details: $error';
          });
        },
      );
    } catch (e) {
      setState(() {
        _lastError =
            'WebSocket unavailable. REST controls still work. Details: $e';
      });
    }
  }

  void _startPositionPolling() {
    _positionTimer?.cancel();
    // Slightly slower polling avoids excessive state churn on the UI thread.
    _positionTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      _refreshPosition(silent: true);
    });
  }

  Future<void> _discoverServers() async {
    if (_discovering) {
      return;
    }
    setState(() {
      _discovering = true;
      _lastError = '';
      _discoveredServers.clear();
    });

    try {
      final discovered = await _pairingDiscoveryService.discoverServers();

      if (!mounted) {
        return;
      }
      setState(() {
        _discoveredServers
          ..clear()
          ..addAll(discovered);

        if (discovered.isNotEmpty) {
          // Discovery service returns best candidates first.
          _baseUrlController.text = discovered.first.baseUrl;
        } else {
          _lastError = 'No servers found in local network.';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastError = 'Discovery failed: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _discovering = false;
        });
      }
    }
  }

  Future<void> _pairAndConnect() async {
    if (_pairing) {
      return;
    }
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() {
        _lastError = 'Pick a discovered server first.';
      });
      return;
    }
    setState(() {
      _pairing = true;
      _lastError = '';
    });
    try {
      _api.configure(baseUrl: baseUrl, token: _tokenController.text.trim());
      final start = await _api.pairingStart(
        deviceId: _deviceId,
        deviceName: 'Flutter Phone',
      );
      final code = await _promptPairingCode(start.pairingId);
      if (code == null) {
        return;
      }
      final confirm = await _api.pairingConfirm(
        pairingId: start.pairingId,
        code: code,
      );
      _tokenController.text = confirm.accessToken;
      _refreshToken = confirm.refreshToken;
      await _saveConfig();
      await _connectAndSync();
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastError = 'Pairing failed: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _pairing = false;
        });
      }
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

  void _handleWsEvent(Map<String, dynamic> event) {
    final eventType =
        event['type']?.toString() ?? event['event']?.toString() ?? '';
    final payload = event['payload'];

    if (eventType == 'playback_ended') {
      unawaited(_handlePlaybackEnded());
      return;
    }

    if (eventType == 'state_changed' ||
        eventType == 'track_changed' ||
        eventType == 'seek_changed' ||
        payload is Map<String, dynamic>) {
      if (payload is Map<String, dynamic>) {
        _applyState(payload);
      }
    }

    if (eventType == 'library_changed' || eventType == 'files_changed') {
      // Server can emit this after upload/rescan; pull a fresh list.
      _refreshLibrary();
    }

    if (eventType == 'error') {
      setState(() {
        if (payload is Map<String, dynamic>) {
          _lastError = payload['message']?.toString() ?? 'Server error';
        } else {
          _lastError = event['message']?.toString() ?? 'Server error';
        }
      });
    }
  }

  void _applyState(Map<String, dynamic> state) {
    final volumeRaw = state['volume'];
    final shuffleRaw = state['shuffle'];
    final repeatRaw = state['repeat_mode'];
    final statusRaw = state['status'] ?? state['state'];
    final trackRaw = state['current_track'] ?? state['track'];
    final currentTrackId = state['current_track_id']?.toString();
    final positionRaw = state['position'];
    final durationRaw = state['duration'];

    String trackTitle = 'No active track';
    if (trackRaw is Map<String, dynamic>) {
      trackTitle = _pickTrackTitle(trackRaw);
    } else if (trackRaw != null) {
      trackTitle = trackRaw.toString();
    }

    final nextVolume = (volumeRaw is num ? volumeRaw.toDouble() : _volume)
        .clamp(0, 100)
        .toDouble();
    final nextShuffle = shuffleRaw is bool ? shuffleRaw : _shuffle;
    final nextRepeatMode = _normalizeRepeatMode(
      repeatRaw?.toString() ?? _repeatMode,
    );
    final nextStatus = statusRaw?.toString() ?? _statusText;
    final nextTrackId = currentTrackId;
    final nextTrackTitle = nextTrackId != null && nextTrackId.isNotEmpty
        ? _resolveTrackTitle(nextTrackId)
        : trackTitle;
    final nextDuration = durationRaw is num && durationRaw.toDouble() > 0
        ? durationRaw.toDouble()
        : _duration;
    final preserveStoppedSeek =
        !_isSeeking &&
        _isStoppedStatus(nextStatus) &&
        _stoppedSeekPosition != null;
    final nextPosition = preserveStoppedSeek
        ? _stoppedSeekPosition!
        : (!_isSeeking && positionRaw is num
              ? positionRaw.toDouble()
              : _position);
    final trackChanged = _currentTrackId != nextTrackId;

    // Skip rebuild when deltas are tiny/no-op; this runs frequently.
    final changed =
        (nextVolume - _volume).abs() > 0.1 ||
        nextShuffle != _shuffle ||
        nextRepeatMode != _repeatMode ||
        nextStatus != _statusText ||
        nextTrackTitle != _currentTrack ||
        nextTrackId != _currentTrackId ||
        (nextDuration - _duration).abs() > 0.1 ||
        (!_isSeeking && (nextPosition - _position).abs() > 0.1);

    if (!changed) {
      return;
    }

    final shouldSyncSystemVolume =
        AndroidSystemVolume.instance.isSupported &&
        (nextVolume - _volume).abs() > 0.1;

    setState(() {
      _volume = nextVolume;
      _shuffle = nextShuffle;
      _repeatMode = nextRepeatMode;
      _statusText = nextStatus;
      _currentTrack = nextTrackTitle;
      _currentTrackId = nextTrackId;
      if (nextTrackId != null && nextTrackId.isNotEmpty) {
        _selectedTrackId = nextTrackId;
      }
      _duration = nextDuration;
      if (!_isSeeking) {
        _position = nextPosition;
      }
      if (!_isStoppedStatus(nextStatus)) {
        _stoppedSeekPosition = null;
      }
    });

    if (shouldSyncSystemVolume) {
      unawaited(_setAndroidSystemVolume(nextVolume));
    }

    if (trackChanged) {
      // Metadata fetch is tied to track identity, not every state event.
      unawaited(_refreshCurrentMetadata());
    }
  }

  Future<void> _refreshState() async {
    try {
      final state = await _api.state();
      _applyState(state);
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _refreshState();
          return;
        }
        await _markSessionExpired();
        return;
      }
      setState(() {
        _lastError = e.toString();
      });
    }
  }

  Future<void> _refreshPosition({bool silent = false}) async {
    try {
      final position = await _api.position();
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
      setState(() {
        _position = nextPosition;
        _duration = nextDuration;
      });
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _refreshPosition(silent: silent);
          return;
        }
        await _markSessionExpired();
        return;
      }
      if (!silent && mounted) {
        setState(() {
          _lastError = e.toString();
        });
      }
    }
  }

  Future<void> _refreshLibrary() async {
    try {
      final library = await _api.library(forceRescan: true);
      setState(() {
        _library = library;
        _playbackSession
          ..setLibrary(library)
          ..hydrateQueueFromCurrentTrack(_currentTrackId);
        _syncQueueState();
        if (library.isNotEmpty && _selectedTrackId == null) {
          _selectedTrackId = library.first.id;
        }
      });
      unawaited(_refreshCurrentMetadata());
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _refreshLibrary();
          return;
        }
        await _markSessionExpired();
        return;
      }
      setState(() {
        _lastError = e.toString();
      });
    }
  }

  Future<void> _refreshCurrentMetadata() async {
    final trackId = _currentTrackId ?? _selectedTrackId;
    if (trackId == null || trackId.isEmpty) {
      if (mounted) {
        setState(() {
          _currentMetadata = null;
          _metadataLoading = false;
        });
      }
      return;
    }
    final cached = _metadataCache[trackId];
    if (cached != null) {
      // Cache hit avoids duplicate metadata requests on repeated state updates.
      if (_currentMetadata?.trackId == cached.trackId && !_metadataLoading) {
        return;
      }
      if (mounted) {
        setState(() {
          _currentMetadata = cached;
          _metadataLoading = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _metadataLoading = true;
      });
    }
    try {
      final raw = await _api.metadata(trackId);
      final parsed = TrackMetadata.fromJson(raw);
      _metadataCache[trackId] = parsed;
      if (!mounted) {
        return;
      }
      setState(() {
        if (_currentTrackId == trackId || _selectedTrackId == trackId) {
          _currentMetadata = parsed;
        }
        _metadataLoading = false;
      });
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _refreshCurrentMetadata();
          return;
        }
        await _markSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _metadataLoading = false;
      });
    }
  }

  Future<void> _sendCommand(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    setState(() {
      _commandBusy = true;
      _commandStatus = 'Sending command...';
      _lastError = '';
    });
    try {
      await _api.command(endpoint, body: body);
      await _refreshState();
      setState(() {
        _commandStatus = 'Done';
      });
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _sendCommand(endpoint, body: body);
          return;
        }
        await _markSessionExpired();
        return;
      }
      setState(() {
        _lastError = e.toString();
        _commandStatus = 'Failed';
      });
    } finally {
      setState(() {
        _commandBusy = false;
      });
    }
  }

  Future<void> _sendVolumeCommand(
    double value, {
    required bool syncSystemVolume,
    required bool showBusy,
  }) async {
    var nextVolume = value.clamp(0, 100).toDouble();
    if (mounted && (nextVolume - _volume).abs() > 0.1) {
      setState(() {
        _volume = nextVolume;
      });
    }
    if (syncSystemVolume) {
      final applied = await _setAndroidSystemVolume(nextVolume);
      if (applied != null) {
        nextVolume = applied;
      }
    }

    if (!_hasServerSession()) {
      return;
    }

    if (showBusy && mounted) {
      setState(() {
        _commandBusy = true;
        _commandStatus = 'Sending command...';
        _lastError = '';
      });
    }
    try {
      await _api.command('/api/volume', body: {'volume': nextVolume.round()});
      if (showBusy && mounted) {
        setState(() {
          _commandStatus = 'Done';
        });
      }
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _sendVolumeCommand(
            nextVolume,
            syncSystemVolume: false,
            showBusy: showBusy,
          );
          return;
        }
        await _markSessionExpired();
        return;
      }
      if (mounted) {
        setState(() {
          _lastError = e.toString();
          if (showBusy) {
            _commandStatus = 'Failed';
          }
        });
      }
    } finally {
      if (showBusy && mounted) {
        setState(() {
          _commandBusy = false;
        });
      }
    }
  }

  Future<void> _setVolume(double value) async {
    _pendingSliderVolumeSync = value.clamp(0, 100).toDouble();
    await _flushPendingVolumeSync();
  }

  Future<void> _seekTo(double value) async {
    if (_isStoppedStatus(_statusText)) {
      setState(() {
        _isSeeking = false;
        _stoppedSeekPosition = value.clamp(0, _duration > 0 ? _duration : value);
        _position = _stoppedSeekPosition!;
        _commandStatus = 'Start position updated';
        _lastError = '';
      });
      return;
    }
    setState(() {
      _isSeeking = true;
      _position = value.clamp(0, _duration > 0 ? _duration : value);
      _commandBusy = true;
      _commandStatus = 'Seeking...';
      _lastError = '';
    });
    try {
      await _api.seek(_position);
      await _refreshPosition();
      setState(() {
        _commandStatus = 'Done';
      });
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _seekTo(value);
          return;
        }
        await _markSessionExpired();
        return;
      }
      setState(() {
        _lastError = e.toString();
        _commandStatus = 'Failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSeeking = false;
          _commandBusy = false;
        });
      }
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
    setState(() {
      _shuffle = nextValue;
      if (nextValue && _playbackSession.shuffleUpcoming()) {
        _syncQueueState();
        _commandStatus = 'Queue shuffled';
      }
    });
    await _updateModes(shuffle: nextValue);
  }

  Future<void> _cycleRepeatMode() async {
    final nextMode = switch (_repeatMode) {
      'off' => 'one',
      'one' => 'all',
      _ => 'off',
    };
    setState(() {
      _repeatMode = nextMode;
    });
    await _updateModes(repeatMode: nextMode);
  }

  void _syncQueueState() {
    _queueSnapshot = _playbackSession.snapshot();
    final queueTrackId = _queueSnapshot.currentTrackId;
    if (queueTrackId != null && queueTrackId.isNotEmpty) {
      _selectedTrackId = queueTrackId;
    }
  }

  Future<void> _runQueueAction(
    Future<void> Function() action, {
    required String inProgressMessage,
  }) async {
    setState(() {
      _commandBusy = true;
      _commandStatus = inProgressMessage;
      _lastError = '';
    });
    try {
      await action();
      await _refreshState();
      if (!mounted) {
        return;
      }
      setState(() {
        _syncQueueState();
        _commandStatus = 'Done';
      });
      unawaited(_refreshCurrentMetadata());
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _runQueueAction(action, inProgressMessage: inProgressMessage);
          return;
        }
        await _markSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _lastError = e.toString();
        _commandStatus = 'Failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _commandBusy = false;
        });
      }
    }
  }

  Future<void> _playTrack(TrackItem track) async {
    await _runQueueAction(() async {
      _stoppedSeekPosition = null;
      await _playbackSession.playLibraryTrack(track, shuffleEnabled: _shuffle);
      _selectedTrackId = track.id;
    }, inProgressMessage: 'Starting playback...');
  }

  Future<void> _playCurrentQueueTrack() async {
    if (_library.isEmpty && _queueSnapshot.isEmpty) {
      setState(() {
        _commandStatus = 'No tracks loaded yet';
      });
      return;
    }
    final startPosition = _isStoppedStatus(_statusText)
        ? _stoppedSeekPosition
        : null;
    await _runQueueAction(
      () async {
        await _playbackSession.playQueueOrBootstrapDefault(
          shuffleEnabled: _shuffle,
        );
        if (startPosition != null && startPosition > 0) {
          await _api.seek(startPosition);
        }
      },
      inProgressMessage: 'Starting playback...',
    );
  }

  Future<void> _playPreviousTrack() async {
    await _runQueueAction(
      () => _playbackSession.playPrevious(),
      inProgressMessage: 'Loading previous track...',
    );
  }

  Future<void> _playNextTrack() async {
    await _runQueueAction(
      () => _playbackSession.playNext(repeatMode: _repeatMode),
      inProgressMessage: 'Loading next track...',
    );
  }

  Future<void> _handlePlaybackEnded() async {
    await _runQueueAction(
      () => _playbackSession.handleNaturalTrackEnd(repeatMode: _repeatMode),
      inProgressMessage: 'Advancing queue...',
    );
  }

  Future<void> _clearQueue() async {
    setState(() {
      _commandBusy = true;
      _commandStatus = 'Clearing queue...';
      _lastError = '';
    });
    try {
      await _playbackSession.clearQueue();
      if (!mounted) {
        return;
      }
      setState(() {
        _syncQueueState();
        _commandStatus = 'Done';
      });
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        final refreshed = await _tryRefreshSession();
        if (refreshed) {
          await _clearQueue();
          return;
        }
        await _markSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _lastError = e.toString();
        _commandStatus = 'Failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _commandBusy = false;
        });
      }
    }
  }

  void _addTrackToQueueStart(TrackItem track) {
    setState(() {
      _playbackSession.addTrackToQueueStart(track.id);
      _selectedTrackId = track.id;
      _syncQueueState();
      _commandStatus = 'Added to queue start';
    });
  }

  void _addTrackToQueueEnd(TrackItem track) {
    setState(() {
      _playbackSession.addTrackToQueueEnd(track.id);
      _selectedTrackId = track.id;
      _syncQueueState();
      _commandStatus = 'Added to queue end';
    });
  }

  void _addTrackAfterCurrent(TrackItem track) {
    setState(() {
      _playbackSession.addTrackAfterCurrent(track.id);
      _selectedTrackId = track.id;
      _syncQueueState();
      _commandStatus = 'Added after current';
    });
  }

  Future<void> _removeQueueEntry(String entryId) async {
    await _runQueueAction(
      () => _playbackSession.removeQueueEntry(entryId),
      inProgressMessage: 'Removing from queue...',
    );
  }

  void _reorderQueueEntry(int oldIndex, int newIndex) {
    final items = _queueSnapshot.items;
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

    setState(() {
      if (oldIndex < newIndex) {
        _playbackSession.moveEntryAfter(movedItem.entryId, targetItem.entryId);
      } else {
        _playbackSession.moveEntryBefore(movedItem.entryId, targetItem.entryId);
      }
      _syncQueueState();
      _commandStatus = 'Queue reordered';
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

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _lastError = '';
    });

    try {
      await _api.uploadFile(
        picked.files.single.path!,
        onProgress: (sentBytes, totalBytes) {
          if (!mounted) {
            return;
          }
          final progress = totalBytes <= 0
              ? 0.0
              : (sentBytes / totalBytes).clamp(0.0, 1.0);
          setState(() {
            _uploadProgress = progress;
          });
        },
      );
      await _refreshLibrary();
    } catch (e) {
      if (_isUnauthorizedError(e)) {
        await _markSessionExpired();
        return;
      }
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      setState(() {
        _uploading = false;
      });
    }
  }

  String _normalizeRepeatMode(String value) {
    if (value == 'one' || value == 'all' || value == 'off') {
      return value;
    }
    return 'off';
  }

  bool _isStoppedStatus(String value) => value.toLowerCase() == 'stopped';

  String _normalizedToken(String raw) {
    final trimmed = raw.trim();
    return trimmed.replaceFirst(RegExp(r'#+$'), '');
  }

  String _pickTrackTitle(Map<String, dynamic> source) {
    for (final key in const ['title', 'name', 'filename', 'path', 'id']) {
      final value = source[key];
      if (value != null && value.toString().isNotEmpty) {
        return value.toString();
      }
    }
    return 'Unknown track';
  }

  String _resolveTrackTitle(String trackId) {
    final match = _library.where((track) => track.id == trackId).firstOrNull;
    if (match != null) {
      return match.title;
    }
    return trackId;
  }

  String _formatDuration(double seconds) {
    final clamped = seconds.isFinite ? seconds.clamp(0, 864000).toInt() : 0;
    final duration = Duration(seconds: clamped);
    String two(int v) => v.toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:${two(duration.inMinutes.remainder(60))}:${two(duration.inSeconds.remainder(60))}';
    }
    return '${duration.inMinutes}:${two(duration.inSeconds.remainder(60))}';
  }

  String _metadataValue(Object? value, {String fallback = '-'}) {
    if (value == null) {
      return fallback;
    }
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sibilarity Music Remote')),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tabIndex,
      onDestinationSelected: (index) => setState(() => _tabIndex = index),
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
                  _connectionCard(context),
                ] else if (_tabIndex == 1) ...[
                  _trackMetadataCard(context),
                  const SizedBox(height: 12),
                  _nowPlayingCard(context),
                  const SizedBox(height: 12),
                  TransportCard(
                    queueSnapshot: _queueSnapshot,
                    commandBusy: _commandBusy,
                    currentTrackTitle: _queueSnapshot.currentTrackId == null
                        ? 'none'
                        : _resolveTrackTitle(_queueSnapshot.currentTrackId!),
                    isPlaying: _statusText.toLowerCase() == 'playing',
                    isPaused: _statusText.toLowerCase() == 'paused',
                    shuffleEnabled: _shuffle,
                    repeatMode: _repeatMode,
                    canGoNext:
                        _queueSnapshot.canGoNext ||
                        (_repeatMode == 'all' &&
                            _queueSnapshot.currentTrackId != null),
                    commandStatus: _commandStatus,
                    onPrev: _playPreviousTrack,
                    onPlay: _playCurrentQueueTrack,
                    onPause: () => _sendCommand('/api/pause'),
                    onResume: () => _sendCommand('/api/resume'),
                    onNext: _playNextTrack,
                    onCycleRepeatMode: _cycleRepeatMode,
                    onToggleShuffle: _toggleShuffle,
                  ),
                  const SizedBox(height: 12),
                  PlaybackQueueCard(
                    queueSnapshot: _queueSnapshot,
                    commandBusy: _commandBusy,
                    onClearQueue: _clearQueue,
                    onRemoveQueueEntry: _removeQueueEntry,
                    onReorderQueueEntry: _reorderQueueEntry,
                  ),
                ] else ...[
                  LibraryCard(
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
  );

  Widget _connectionCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _serverHealthy ? Icons.cloud_done : Icons.cloud_off,
                  color: _serverHealthy ? colors.primary : colors.error,
                ),
                const SizedBox(width: 8),
                Text(
                  _statusText,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns),
              title: const Text('Selected server'),
              subtitle: Text(
                _baseUrlController.text.trim().isEmpty
                    ? 'Not selected yet'
                    : _baseUrlController.text.trim(),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phonelink_lock),
              title: const Text('Pairing status'),
              subtitle: Text(
                _normalizedToken(_tokenController.text).isEmpty
                    ? 'Not paired'
                    : 'Paired',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: (_busy || _backgroundSyncing) ? null : _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _pairing ? null : _pairAndConnect,
                  icon: const Icon(Icons.phonelink_lock),
                  label: Text(_pairing ? 'Pairing...' : 'Pair & Connect'),
                ),
                OutlinedButton.icon(
                  onPressed: _discovering ? null : _discoverServers,
                  icon: const Icon(Icons.travel_explore),
                  label: Text(_discovering ? 'Discovering...' : 'Discover'),
                ),
                OutlinedButton.icon(
                  onPressed: _refreshState,
                  icon: const Icon(Icons.update),
                  label: const Text('State'),
                ),
              ],
            ),
            if (_discoveredServers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Discovered servers',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ..._discoveredServers.map(
                (server) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.speaker_group),
                  title: Text(server.name),
                  subtitle: Text(server.baseUrl),
                  trailing: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _baseUrlController.text = server.baseUrl;
                      });
                    },
                    child: const Text('Select'),
                  ),
                ),
              ),
            ],
            if (_lastError.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_lastError, style: TextStyle(color: colors.error)),
            ],
            if (_initializing || _backgroundSyncing) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Text(
                _initializing ? 'Initializing...' : 'Syncing in background...',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _nowPlayingCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Now Playing', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(_currentTrack, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text('Status: $_statusText'),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(_formatDuration(_position)),
              const Spacer(),
              Text(_formatDuration(_duration)),
            ],
          ),
          Slider(
            value: (_duration <= 0 ? 0 : _position.clamp(0, _duration))
                .toDouble(),
            max: _duration > 0 ? _duration : 1,
            onChanged: _duration > 0
                ? (value) {
                    setState(() {
                      _isSeeking = true;
                      _position = value;
                    });
                  }
                : null,
            onChangeEnd: _duration > 0 ? _seekTo : null,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.volume_up),
              Expanded(
                child: Slider(
                  value: _volume,
                  max: 100,
                  divisions: 100,
                  label: _volume.round().toString(),
                  onChanged: _onVolumeSliderChanged,
                  onChangeEnd: _setVolume,
                ),
              ),
              Text('${_volume.round()}%'),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _trackMetadataCard(BuildContext context) {
    final metadata = _currentMetadata;
    final title = metadata?.title ?? _currentTrack;
    final subtitle = metadata?.artist ?? 'Unknown artist';

    ImageProvider<Object>? coverProvider;
    if (metadata?.coverBytes != null) {
      coverProvider = MemoryImage(metadata!.coverBytes!);
    } else if ((metadata?.coverUrl ?? '').isNotEmpty) {
      coverProvider = NetworkImage(metadata!.coverUrl!);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 110,
                    height: 110,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: coverProvider == null
                        ? const Icon(Icons.album, size: 48)
                        : Image(image: coverProvider, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_metadataLoading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _metaChip('Album', _metadataValue(metadata?.album)),
                _metaChip('Year', _metadataValue(metadata?.year)),
                _metaChip(
                  'Bitrate',
                  metadata?.bitrate != null ? '${metadata!.bitrate} kbps' : '-',
                ),
                _metaChip('Source', _metadataValue(metadata?.source)),
                _metaChip('Found', metadata?.found ?? false ? 'yes' : 'no'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(String label, String value) =>
      Chip(label: Text('$label: $value'), visualDensity: VisualDensity.compact);

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
