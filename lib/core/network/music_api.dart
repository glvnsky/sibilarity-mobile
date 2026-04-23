import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/features/pairing/domain/models/pairing_result.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
    const wsPath = '/ws';
    final wsUri = Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
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

  Future<void> seek(double position) => command('/api/seek', body: {'position': position});

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
