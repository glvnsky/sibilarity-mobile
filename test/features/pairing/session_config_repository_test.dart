import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/features/pairing/data/session_config_repository.dart';
import 'package:music_remote_app/features/pairing/domain/models/session_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SessionConfigRepository', () {
    late SessionConfigRepository repository;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      repository = SessionConfigRepository();
    });

    test('load returns persisted session config', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'base_url': 'http://server:8000',
        'api_token': 'token-1',
        'refresh_token': 'refresh-1',
        'device_id': 'device-1',
      });

      final config = await repository.load();

      expect(config.baseUrl, 'http://server:8000');
      expect(config.accessToken, 'token-1');
      expect(config.refreshToken, 'refresh-1');
      expect(config.deviceId, 'device-1');
    });

    test('load creates and persists device id when missing', () async {
      final config = await repository.load();
      final prefs = await SharedPreferences.getInstance();

      expect(config.deviceId, startsWith('mobile-'));
      expect(prefs.getString('device_id'), config.deviceId);
    });

    test('save writes all session config fields', () async {
      const config = SessionConfig(
        baseUrl: 'http://host:8000',
        accessToken: 'token-2',
        refreshToken: 'refresh-2',
        deviceId: 'device-2',
      );

      await repository.save(config);
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getString('base_url'), config.baseUrl);
      expect(prefs.getString('api_token'), config.accessToken);
      expect(prefs.getString('refresh_token'), config.refreshToken);
      expect(prefs.getString('device_id'), config.deviceId);
    });

    test('clearTokens removes tokens and preserves base url and device id', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'base_url': 'http://server:8000',
        'api_token': 'token-1',
        'refresh_token': 'refresh-1',
        'device_id': 'device-1',
      });

      await repository.clearTokens();
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getString('base_url'), 'http://server:8000');
      expect(prefs.getString('api_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
      expect(prefs.getString('device_id'), 'device-1');
    });

    test('clearConnection removes base url and tokens but keeps device id', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'base_url': 'http://server:8000',
        'api_token': 'token-1',
        'refresh_token': 'refresh-1',
        'device_id': 'device-1',
      });

      await repository.clearConnection();
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getString('base_url'), isNull);
      expect(prefs.getString('api_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
      expect(prefs.getString('device_id'), 'device-1');
    });
  });
}
