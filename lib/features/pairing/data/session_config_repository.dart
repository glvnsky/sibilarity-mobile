import 'dart:math';

import 'package:music_remote_app/features/pairing/domain/models/session_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionConfigRepository {
  Future<SessionConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_baseUrlKey) ?? '';
    final accessToken = prefs.getString(_accessTokenKey) ?? '';
    final refreshToken = prefs.getString(_refreshTokenKey) ?? '';
    final storedDeviceId = prefs.getString(_deviceIdKey);
    final deviceId = (storedDeviceId != null && storedDeviceId.isNotEmpty)
        ? storedDeviceId
        : await _createAndPersistDeviceId(prefs);

    return SessionConfig(
      baseUrl: baseUrl,
      accessToken: accessToken,
      refreshToken: refreshToken,
      deviceId: deviceId,
    );
  }

  Future<void> save(SessionConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, config.baseUrl);
    await prefs.setString(_accessTokenKey, config.accessToken);
    await prefs.setString(_refreshTokenKey, config.refreshToken);
    await prefs.setString(_deviceIdKey, config.deviceId);
  }

  Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
  }

  Future<void> clearConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_baseUrlKey);
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
  }

  Future<String> _createAndPersistDeviceId(SharedPreferences prefs) async {
    final randomPart = Random()
        .nextInt(0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    final deviceId =
        'mobile-${DateTime.now().millisecondsSinceEpoch}-$randomPart';
    await prefs.setString(_deviceIdKey, deviceId);
    return deviceId;
  }
}

const String _baseUrlKey = 'base_url';
const String _accessTokenKey = 'api_token';
const String _refreshTokenKey = 'refresh_token';
const String _deviceIdKey = 'device_id';
