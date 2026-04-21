import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  runApp(const MusicRemoteApp());
}

class MusicRemoteApp extends StatelessWidget {
  const MusicRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sibilarity Music Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B57D0),
          brightness: Brightness.light,
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const RemoteHomePage(),
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  static const _defaultBaseUrl = 'http://192.168.1.79:8000';
  static const _legacyBaseUrl = 'http://192.168.1.2:8000';

  final _baseUrlController = TextEditingController(text: _defaultBaseUrl);
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
  String? _selectedTrackId;
  String _lastError = '';

  List<TrackItem> _library = const [];

  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;
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
    if (base != null && base.isNotEmpty) {
      _baseUrlController.text = base == _legacyBaseUrl ? _defaultBaseUrl : base;
    }
    if (token != null) {
      _tokenController.text = token;
    }
    await _connectAndSync();
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base_url', _baseUrlController.text.trim());
    await prefs.setString('api_token', _normalizedToken(_tokenController.text));
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
        _statusText = 'Base URL is required';
        _lastError = 'Please enter backend URL.';
      });
      return;
    }
    if (token.isEmpty) {
      setState(() {
        _busy = false;
        _serverHealthy = false;
        _statusText = 'API token is required';
        _lastError = 'Please enter API token from your server config.';
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
      await _saveConfig();
    } catch (e) {
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
        onError: (error) {
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
    } catch (e) {
      setState(() {
        _lastError = e.toString();
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
    final picked = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (picked == null || picked.files.single.path == null) {
      return;
    }

    setState(() {
      _busy = true;
      _lastError = '';
    });

    try {
      await _api.uploadFile(picked.files.single.path!);
      await _refreshLibrary();
    } catch (e) {
      setState(() {
        _lastError = e.toString();
      });
    } finally {
      setState(() {
        _busy = false;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          NavigationDestination(icon: Icon(Icons.equalizer), label: 'Player'),
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
  }

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
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: _defaultBaseUrl,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API token',
                border: OutlineInputBorder(),
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

  Widget _nowPlayingCard(BuildContext context) {
    return Card(
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
              min: 0,
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
                    min: 0,
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
  }

  Widget _transportCard(BuildContext context) {
    return Card(
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
  }

  Widget _modesCard(BuildContext context) {
    return Card(
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
  }

  Widget _libraryCard(BuildContext context) {
    return Card(
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
                  onPressed: _uploadTrack,
                  icon: const Icon(Icons.upload_file),
                ),
              ],
            ),
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
}

class TrackItem {
  const TrackItem({required this.id, required this.title});

  final String id;
  final String title;
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
    final wsPath = '/ws';
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

  Future<void> uploadFile(String path) async {
    final request = http.MultipartRequest('POST', _buildUri('/api/upload'));
    request.headers.addAll(_headers);
    request.files.add(await http.MultipartFile.fromPath('file', path));
    final response = await request.send();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Upload failed: HTTP ${response.statusCode}');
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
