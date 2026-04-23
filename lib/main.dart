import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const MusicRemoteApp());
}

class MusicRemoteApp extends StatelessWidget {
  const MusicRemoteApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'Sibilarity Music Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B57D0),
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const RemoteHomePage(),
    );
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _api = MusicApi();

  int _tabIndex = 0;
  bool _busy = false;
  bool _commandBusy = false;
  bool _serverHealthy = false;
  double _volume = 50;
  double _position = 0;
  double _duration = 0;
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

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSubscription;
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    _wsSubscription?.cancel();
    _channel?.sink.close();
    _positionTimer?.cancel();
    super.dispose();
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
      final randomPart = Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
      _deviceId = 'mobile-${DateTime.now().millisecondsSinceEpoch}-$randomPart';
      await prefs.setString('device_id', _deviceId);
    }
    if (mounted) {
      setState(() {
        _serverHealthy = false;
        _statusText = 'Ready for pairing';
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

  Future<void> _connectAndSync() async {
    setState(() {
      _busy = true;
      _lastError = '';
    });

    final baseUrl = _baseUrlController.text.trim();
    final token = _normalizedToken(_tokenController.text);
    if (baseUrl.isEmpty) {
      setState(() {
        _busy = false;
        _serverHealthy = false;
        _statusText = 'Server is not selected';
        _lastError = 'Use Discover and pick a server first.';
      });
      return;
    }
    if (token.isEmpty) {
      setState(() {
        _busy = false;
        _serverHealthy = false;
        _statusText = 'Device is not paired';
        _lastError = 'Tap "Pair & Connect" to authorize this device.';
      });
      return;
    }

    try {
      _api.configure(baseUrl: baseUrl, token: token);
      final health = await _api.health();
      final state = await _api.state();
      final libraryData = await _api.library();

      _applyState(state);
      setState(() {
        _serverHealthy = health;
        _library = libraryData;
        if (libraryData.isNotEmpty && !libraryData.any((track) => track.id == _selectedTrackId)) {
          _selectedTrackId = libraryData.first.id;
        }
        _statusText = health ? 'Connected' : 'No response from /health';
      });

      _connectWebSocket();
      _startPositionPolling();
      await _refreshPosition();
      await _refreshCurrentMetadata();
      await _saveConfig();
    } catch (e) {
      if (_refreshToken.isNotEmpty && e.toString().contains('401')) {
        try {
          final newToken = await _api.refreshAccessToken(_refreshToken);
          _tokenController.text = newToken;
          await _saveConfig();
          await _connectAndSync();
          return;
        } catch (_) {}
      }
      setState(() {
        _serverHealthy = false;
        _lastError = e.toString();
        _statusText = 'Connection failed';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  void _connectWebSocket() {
    _wsSubscription?.cancel();
    _channel?.sink.close();

    try {
      _channel = _api.openSocket();
      _wsSubscription = _channel!.stream.listen(
        (message) {
          final decoded = _tryDecode(message);
          if (decoded is Map<String, dynamic>) {
            _handleWsEvent(decoded);
          }
        },
        onError: (Object error) {
          setState(() {
            _lastError = 'WebSocket unavailable. REST controls still work. Details: $error';
          });
        },
      );
    } catch (e) {
      setState(() {
        _lastError = 'WebSocket unavailable. REST controls still work. Details: $e';
      });
    }
  }

  void _startPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
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

    final mdns = MDnsClient();
    final discovered = <DiscoveredServer>{};
    try {
      await mdns.start();
      final ptrRecords = await mdns
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_sibilarity._tcp.local'),
          )
          .take(20)
          .timeout(
            const Duration(seconds: 4),
            onTimeout: (sink) => sink.close(),
          )
          .toList();

      for (final ptr in ptrRecords) {
        final srvRecords = await mdns
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
            )
            .take(2)
            .timeout(
              const Duration(seconds: 2),
              onTimeout: (sink) => sink.close(),
            )
            .toList();
        for (final srv in srvRecords) {
          final hostRecords = await mdns
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )
              .take(2)
              .timeout(
                const Duration(seconds: 2),
                onTimeout: (sink) => sink.close(),
              )
              .toList();
          final host = hostRecords.isNotEmpty ? hostRecords.first.address.address : srv.target.replaceFirst(RegExp(r'\.$'), '');
          if (host.isEmpty) {
            continue;
          }
          final deviceName = ptr.domainName.split('._sibilarity').first;
          discovered.add(
            DiscoveredServer(
              name: deviceName.isEmpty ? host : deviceName,
              host: host,
              port: srv.port,
            ),
          );
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _discoveredServers
          ..clear()
          ..addAll(discovered.toList()..sort((a, b) => a.name.compareTo(b.name)));
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastError = 'Discovery failed: $e';
        });
      }
    } finally {
      mdns.stop();
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
      final confirm = await _api.pairingConfirm(pairingId: start.pairingId, code: code);
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
    final eventType = event['type']?.toString() ?? event['event']?.toString() ?? '';
    final payload = event['payload'];

    if (eventType == 'state_changed' || eventType == 'track_changed' || eventType == 'seek_changed' || payload is Map<String, dynamic>) {
      if (payload is Map<String, dynamic>) {
        _applyState(payload);
      }
    }

    if (eventType == 'library_changed' || eventType == 'files_changed') {
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

    setState(() {
      _volume = (volumeRaw is num ? volumeRaw.toDouble() : _volume).clamp(0, 100);
      _shuffle = shuffleRaw is bool ? shuffleRaw : _shuffle;
      _repeatMode = _normalizeRepeatMode(repeatRaw?.toString() ?? _repeatMode);
      _statusText = statusRaw?.toString() ?? _statusText;
      _currentTrack = currentTrackId != null && currentTrackId.isNotEmpty ? _resolveTrackTitle(currentTrackId) : trackTitle;
      _currentTrackId = currentTrackId;
      if (currentTrackId != null && currentTrackId.isNotEmpty) {
        _selectedTrackId = currentTrackId;
      }
      if (durationRaw is num && durationRaw.toDouble() > 0) {
        _duration = durationRaw.toDouble();
      }
      if (!_isSeeking) {
        if (positionRaw is num) {
          _position = positionRaw.toDouble();
        }
      }
    });
    _refreshCurrentMetadata();
  }

  Future<void> _refreshState() async {
    try {
      final state = await _api.state();
      _applyState(state);
    } catch (e) {
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
      setState(() {
        final pos = position['position'];
        final dur = position['duration'];
        if (!_isSeeking) {
          if (pos is num) {
            _position = pos.toDouble();
          }
        }
        if (dur is num && dur.toDouble() > 0) {
          _duration = dur.toDouble();
        }
      });
    } catch (e) {
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
        if (library.isNotEmpty && _selectedTrackId == null) {
          _selectedTrackId = library.first.id;
        }
      });
      unawaited(_refreshCurrentMetadata());
    } catch (e) {
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
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _metadataLoading = false;
      });
    }
  }

  Future<void> _sendCommand(String endpoint, {Map<String, dynamic>? body}) async {
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

  Future<void> _setVolume(double value) async {
    setState(() {
      _volume = value;
    });
    await _sendCommand('/api/volume', body: {'volume': value.round()});
  }

  Future<void> _seekTo(double value) async {
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

  Future<void> _playTrack(TrackItem track) async {
    final payload = <String, dynamic>{
      'track_id': track.id,
    };
    await _sendCommand('/api/play', body: payload);
    setState(() {
      _selectedTrackId = track.id;
    });
    unawaited(_refreshCurrentMetadata());
  }

  Future<void> _playSelectedTrack() async {
    if (_library.isEmpty) {
      setState(() {
        _commandStatus = 'No tracks loaded yet';
      });
      return;
    }
    final selectedId = _selectedTrackId ?? _library.first.id;
    final selectedTrack = _library.where((track) => track.id == selectedId).firstOrNull ?? _library.first;
    await _playTrack(selectedTrack);
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
          final progress = totalBytes <= 0 ? 0.0 : (sentBytes / totalBytes).clamp(0.0, 1.0);
          setState(() {
            _uploadProgress = progress;
          });
        },
      );
      await _refreshLibrary();
    } catch (e) {
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
      appBar: AppBar(
        title: const Text('Sibilarity Music Remote'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _connectAndSync,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.album), label: 'Track'),
          NavigationDestination(icon: Icon(Icons.equalizer), label: 'Controls'),
          NavigationDestination(icon: Icon(Icons.library_music), label: 'Library'),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _connectAndSync,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _connectionCard(context),
                  const SizedBox(height: 12),
                  if (_tabIndex == 0) ...[
                    _trackMetadataCard(context),
                  ] else if (_tabIndex == 1) ...[
                    _nowPlayingCard(context),
                    const SizedBox(height: 12),
                    _transportCard(context),
                    const SizedBox(height: 12),
                    _modesCard(context),
                  ] else ...[
                    _libraryCard(context),
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
                FilledButton.icon(
                  onPressed: _connectAndSync,
                  icon: const Icon(Icons.link),
                  label: const Text('Connect'),
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
                OutlinedButton.icon(
                  onPressed: _refreshLibrary,
                  icon: const Icon(Icons.queue_music),
                  label: const Text('Library'),
                ),
              ],
            ),
            if (_discoveredServers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Discovered servers', style: Theme.of(context).textTheme.titleSmall),
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
              Text(
                _lastError,
                style: TextStyle(color: colors.error),
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
              value: (_duration <= 0 ? 0 : _position.clamp(0, _duration)).toDouble(),
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
                    onChanged: (v) => setState(() => _volume = v),
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
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: coverProvider == null
                        ? const Icon(Icons.album, size: 48)
                        : Image(
                            image: coverProvider,
                            fit: BoxFit.cover,
                          ),
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
                      const SizedBox(height: 6),
                      Text('Status: $_statusText'),
                      Text('${_formatDuration(_position)} / ${_formatDuration(_duration)}'),
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
                _metaChip('Genre', _metadataValue(metadata?.genre)),
                _metaChip('Track #', _metadataValue(metadata?.trackNumber)),
                _metaChip('Bitrate', metadata?.bitrate != null ? '${metadata!.bitrate} kbps' : '-'),
                _metaChip('Sample rate', metadata?.sampleRate != null ? '${metadata!.sampleRate} Hz' : '-'),
                _metaChip('Channels', _metadataValue(metadata?.channels)),
                _metaChip('Source', _metadataValue(metadata?.source)),
                _metaChip('Found', metadata?.found ?? false ? 'yes' : 'no'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(String label, String value) => Chip(
      label: Text('$label: $value'),
      visualDensity: VisualDensity.compact,
    );

  Widget _transportCard(BuildContext context) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Transport', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_library.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: _library.any((track) => track.id == _selectedTrackId) ? _selectedTrackId : _library.first.id,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Track to play',
                  border: OutlineInputBorder(),
                ),
                items: _library
                    .map(
                      (track) => DropdownMenuItem<String>(
                        value: track.id,
                        child: Text(
                          track.title,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _selectedTrackId = value;
                  });
                },
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _commandBusy ? null : () => _sendCommand('/api/prev'),
                  icon: const Icon(Icons.skip_previous),
                  label: const Text('Prev'),
                ),
                FilledButton.icon(
                  onPressed: _commandBusy ? null : _playSelectedTrack,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                FilledButton.icon(
                  onPressed: _commandBusy ? null : () => _sendCommand('/api/pause'),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                FilledButton.icon(
                  onPressed: _commandBusy ? null : () => _sendCommand('/api/resume'),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _commandBusy ? null : () => _sendCommand('/api/stop'),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _commandBusy ? null : () => _sendCommand('/api/next'),
                  icon: const Icon(Icons.skip_next),
                  label: const Text('Next'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _commandBusy ? 'Applying command...' : _commandStatus,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );

  Widget _modesCard(BuildContext context) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Modes', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _shuffle,
              title: const Text('Shuffle'),
              contentPadding: EdgeInsets.zero,
              onChanged: (value) {
                setState(() => _shuffle = value);
                _updateModes(shuffle: value);
              },
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(value: 'off', label: Text('Repeat Off')),
                ButtonSegment<String>(value: 'one', label: Text('Repeat One')),
                ButtonSegment<String>(value: 'all', label: Text('Repeat All')),
              ],
              selected: {_repeatMode},
              onSelectionChanged: (selection) {
                final mode = selection.first;
                setState(() => _repeatMode = mode);
                _updateModes(repeatMode: mode);
              },
            ),
          ],
        ),
      ),
    );

  Widget _libraryCard(BuildContext context) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Tracks (${_library.length})', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'Upload file',
                  onPressed: _uploading ? null : _uploadTrack,
                  icon: const Icon(Icons.upload_file),
                ),
              ],
            ),
            if (_uploading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _uploadProgress),
              const SizedBox(height: 6),
              Text('Uploading... ${(_uploadProgress * 100).toStringAsFixed(0)}%'),
            ],
            const SizedBox(height: 8),
            if (_library.isEmpty)
              const Text('Library is empty or server returned no tracks.')
            else
              ..._library.map(
                (track) => ListTile(
                  leading: const Icon(Icons.music_note),
                  title: Text(track.title),
                  subtitle: Text(track.id),
                  trailing: IconButton(
                    onPressed: () => _playTrack(track),
                    icon: const Icon(Icons.play_circle_fill),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
}

class TrackItem {
  const TrackItem({required this.id, required this.title});

  final String id;
  final String title;
}

class DiscoveredServer {
  const DiscoveredServer({
    required this.name,
    required this.host,
    required this.port,
  });

  final String name;
  final String host;
  final int port;

  String get baseUrl => 'http://$host:$port';

  @override
  bool operator ==(Object other) => other is DiscoveredServer && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

class PairingStartResult {
  const PairingStartResult({required this.pairingId});

  final String pairingId;
}

class PairingConfirmResult {
  const PairingConfirmResult({
    required this.accessToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String refreshToken;
}

class TrackMetadata {
  const TrackMetadata({
    required this.trackId,
    required this.source,
    required this.found,
    this.title,
    this.artist,
    this.album,
    this.year,
    this.genre,
    this.trackNumber,
    this.duration,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.coverDataUrl,
    this.coverUrl,
    this.coverBytes,
  });

  factory TrackMetadata.fromJson(Map<String, dynamic> json) {
    Uint8List? decodedCoverBytes;
    final rawCoverData = json['cover_data_url']?.toString();
    if (rawCoverData != null && rawCoverData.isNotEmpty) {
      final comma = rawCoverData.indexOf(',');
      if (comma >= 0 && comma + 1 < rawCoverData.length) {
        try {
          decodedCoverBytes = base64Decode(rawCoverData.substring(comma + 1));
        } catch (_) {
          decodedCoverBytes = null;
        }
      }
    }

    return TrackMetadata(
      trackId: json['track_id']?.toString() ?? '',
      source: json['source']?.toString() ?? 'unknown',
      found: json['found'] == true,
      title: json['title']?.toString(),
      artist: json['artist']?.toString(),
      album: json['album']?.toString(),
      year: json['year'] is num ? (json['year'] as num).toInt() : null,
      genre: json['genre']?.toString(),
      trackNumber: json['track_number'] is num ? (json['track_number'] as num).toInt() : null,
      duration: json['duration'] is num ? (json['duration'] as num).toDouble() : null,
      bitrate: json['bitrate'] is num ? (json['bitrate'] as num).toInt() : null,
      sampleRate: json['sample_rate'] is num ? (json['sample_rate'] as num).toInt() : null,
      channels: json['channels'] is num ? (json['channels'] as num).toInt() : null,
      coverDataUrl: json['cover_data_url']?.toString(),
      coverUrl: json['cover_url']?.toString(),
      coverBytes: decodedCoverBytes,
    );
  }

  final String trackId;
  final String source;
  final bool found;
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final String? genre;
  final int? trackNumber;
  final double? duration;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final String? coverDataUrl;
  final String? coverUrl;
  final Uint8List? coverBytes;
}

class MusicApi {
  String _baseUrl = '';
  String _token = '';

  void configure({required String baseUrl, required String token}) {
    _baseUrl = baseUrl;
    _token = token;
  }

  WebSocketChannel openSocket() {
    final base = Uri.parse(_baseUrl.trim());
    final token = _token.trim().replaceFirst(RegExp(r'#+$'), '');
    final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
    const wsPath = '/ws';
    final wsUri = Uri(
      scheme: wsScheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: wsPath,
    );
    return IOWebSocketChannel.connect(
      wsUri,
      headers: <String, dynamic>{
        'X-Api-Token': token,
      },
    );
  }

  Future<bool> health() async {
    final response = await http.get(
      _buildUri('/health'),
      headers: _headers,
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  Future<Map<String, dynamic>> state() async {
    final body = await _getJson('/api/state');
    if (body is Map<String, dynamic>) {
      return body;
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> position() async {
    final body = await _getJson('/api/position');
    if (body is Map<String, dynamic>) {
      return body;
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> metadata(String trackId) async {
    final encodedId = Uri.encodeComponent(trackId);
    final body = await _getJson('/api/metadata/$encodedId');
    if (body is Map<String, dynamic>) {
      return body;
    }
    return <String, dynamic>{};
  }

  Future<PairingStartResult> pairingStart({
    required String deviceId,
    required String deviceName,
  }) async {
    final response = await http.post(
      _buildUri('/api/pairing/start'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'device_id': deviceId,
        'device_name': deviceName,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Pairing start failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final pairingId = body['pairing_id']?.toString() ?? '';
    if (pairingId.isEmpty) {
      throw Exception('Pairing start failed: missing pairing_id');
    }
    return PairingStartResult(pairingId: pairingId);
  }

  Future<PairingConfirmResult> pairingConfirm({
    required String pairingId,
    required String code,
  }) async {
    final response = await http.post(
      _buildUri('/api/pairing/confirm'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'pairing_id': pairingId,
        'code': code,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Pairing confirm failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = body['access_token']?.toString() ?? '';
    final refreshToken = body['refresh_token']?.toString() ?? '';
    if (accessToken.isEmpty || refreshToken.isEmpty) {
      throw Exception('Pairing confirm failed: missing tokens');
    }
    return PairingConfirmResult(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<String> refreshAccessToken(String refreshToken) async {
    final response = await http.post(
      _buildUri('/api/auth/refresh'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'refresh_token': refreshToken,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Token refresh failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = body['access_token']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw Exception('Token refresh failed: missing access_token');
    }
    return accessToken;
  }

  Future<List<TrackItem>> library({bool forceRescan = false}) async {
    final body = await _getJson(forceRescan ? '/api/library/files' : '/api/files');
    final items = _extractList(body);
    final tracks = <TrackItem>[];

    for (final item in items) {
      if (item is Map<String, dynamic>) {
        final id = _pickFirst(item, const ['id', 'track_id', 'path', 'name', 'filename']);
        final title = _pickFirst(item, const ['title', 'name', 'filename', 'path', 'id']);
        if (id.isNotEmpty) {
          tracks.add(TrackItem(id: id, title: title.isEmpty ? id : title));
        }
      } else if (item != null) {
        final value = item.toString();
        tracks.add(TrackItem(id: value, title: value));
      }
    }
    return tracks;
  }

  Future<void> uploadFile(String path, {void Function(int sentBytes, int totalBytes)? onProgress}) async {
    final file = File(path);
    final totalBytes = await file.length();
    var sentBytes = 0;
    final fileName = path.split(RegExp(r'[\\/]')).last;

    final request = http.MultipartRequest('POST', _buildUri('/api/upload'));
    request.headers.addAll(_headers);
    final stream = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sentBytes += chunk.length;
          onProgress?.call(sentBytes, totalBytes);
          sink.add(chunk);
        },
      ),
    );
    request.files.add(http.MultipartFile('file', stream, totalBytes, filename: fileName));
    final response = await request.send();
    onProgress?.call(totalBytes, totalBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw Exception('Upload failed: HTTP ${response.statusCode} ${body.trim()}');
    }
  }

  Future<void> command(String endpoint, {Map<String, dynamic>? body}) async {
    final encoded = body == null ? null : jsonEncode(body);
    final headers = {
      ..._headers,
      if (body != null) 'Content-Type': 'application/json',
    };

    final response = await http.post(
      _buildUri(endpoint),
      headers: headers,
      body: encoded,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Request failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> seek(double position) async {
    await command('/api/seek', body: {'position': position});
  }

  Future<dynamic> _getJson(String endpoint) async {
    final response = await http.get(
      _buildUri(endpoint),
      headers: _headers,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Request failed: ${response.statusCode} ${response.body}');
    }

    if (response.body.isEmpty) {
      return null;
    }

    return jsonDecode(response.body);
  }

  Uri _buildUri(String path, {Map<String, String>? query}) {
    final base = Uri.parse(_baseUrl);
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return base.replace(
      path: normalizedPath,
      queryParameters: query,
    );
  }

  Map<String, String> get _headers => {
        if (_token.isNotEmpty) 'X-Api-Token': _token,
      };

  List<dynamic> _extractList(dynamic body) {
    if (body is List) {
      return body;
    }
    if (body is Map<String, dynamic>) {
      for (final key in const ['tracks', 'items', 'library', 'data', 'files']) {
        final candidate = body[key];
        if (candidate is List) {
          return candidate;
        }
      }
    }
    return const [];
  }

  String _pickFirst(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value != null) {
        final text = value.toString();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
    return '';
  }
}
