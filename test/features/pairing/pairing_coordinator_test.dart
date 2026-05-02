import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/pairing/application/pairing_coordinator.dart';
import 'package:music_remote_app/features/pairing/data/pairing_discovery_service.dart';
import 'package:music_remote_app/features/pairing/data/session_config_repository.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';
import 'package:music_remote_app/features/pairing/domain/models/pairing_result.dart';
import 'package:music_remote_app/features/pairing/domain/models/session_config.dart';

class _FakeMusicApi extends MusicApi {
  PairingStartResult pairingStartResult = const PairingStartResult(
    pairingId: 'pairing-1',
  );
  PairingConfirmResult pairingConfirmResult = const PairingConfirmResult(
    accessToken: 'token-1',
    refreshToken: 'refresh-1',
  );
  String refreshedAccessToken = 'refreshed-token';
  bool throwOnRefresh = false;
  String configuredBaseUrl = '';
  String configuredToken = '';

  @override
  void configure({required String baseUrl, required String token}) {
    configuredBaseUrl = baseUrl;
    configuredToken = token;
  }

  @override
  Future<PairingStartResult> pairingStart({
    required String deviceId,
    required String deviceName,
  }) async => pairingStartResult;

  @override
  Future<PairingConfirmResult> pairingConfirm({
    required String pairingId,
    required String code,
  }) async => pairingConfirmResult;

  @override
  Future<String> refreshAccessToken(String refreshToken) async {
    if (throwOnRefresh) {
      throw Exception('refresh failed');
    }
    return refreshedAccessToken;
  }
}

class _FakePairingDiscoveryService extends PairingDiscoveryService {
  _FakePairingDiscoveryService(this.result);

  final List<DiscoveredServer> result;

  @override
  Future<List<DiscoveredServer>> discoverServers() async => result;
}

class _RecordingSessionConfigRepository extends SessionConfigRepository {
  SessionConfig? savedConfig;
  var clearTokensCalls = 0;

  @override
  Future<void> save(SessionConfig config) async {
    savedConfig = config;
  }

  @override
  Future<void> clearTokens() async {
    clearTokensCalls += 1;
  }
}

void main() {
  group('PairingCoordinator', () {
    test('discoverServers returns discovery results', () async {
      final coordinator = PairingCoordinator(
        api: _FakeMusicApi(),
        discoveryService: _FakePairingDiscoveryService(
          const <DiscoveredServer>[
            DiscoveredServer(name: 'Server', host: '127.0.0.1', port: 8000),
          ],
        ),
        sessionConfigRepository: _RecordingSessionConfigRepository(),
      );

      final servers = await coordinator.discoverServers();

      expect(servers, hasLength(1));
      expect(servers.single.name, 'Server');
      expect(servers.single.baseUrl, 'http://127.0.0.1:8000');
    });

    test('pairAndPersistSession saves confirmed session config', () async {
      final api = _FakeMusicApi();
      final repository = _RecordingSessionConfigRepository();
      final coordinator = PairingCoordinator(
        api: api,
        discoveryService: _FakePairingDiscoveryService(const <DiscoveredServer>[]),
        sessionConfigRepository: repository,
      );

      final config = await coordinator.pairAndPersistSession(
        baseUrl: 'http://server:8000',
        currentToken: '',
        deviceId: 'device-1',
        requestPairingCode: (_) async => '123456',
      );

      expect(api.configuredBaseUrl, 'http://server:8000');
      expect(config, isNotNull);
      expect(config!.accessToken, 'token-1');
      expect(config.refreshToken, 'refresh-1');
      expect(repository.savedConfig?.baseUrl, 'http://server:8000');
      expect(repository.savedConfig?.deviceId, 'device-1');
    });

    test('pairAndPersistSession returns null when code input is cancelled', () async {
      final repository = _RecordingSessionConfigRepository();
      final coordinator = PairingCoordinator(
        api: _FakeMusicApi(),
        discoveryService: _FakePairingDiscoveryService(const <DiscoveredServer>[]),
        sessionConfigRepository: repository,
      );

      final config = await coordinator.pairAndPersistSession(
        baseUrl: 'http://server:8000',
        currentToken: '',
        deviceId: 'device-1',
        requestPairingCode: (_) async => null,
      );

      expect(config, isNull);
      expect(repository.savedConfig, isNull);
    });

    test('refreshSession persists refreshed access token', () async {
      final api = _FakeMusicApi()..refreshedAccessToken = 'token-2';
      final repository = _RecordingSessionConfigRepository();
      final coordinator = PairingCoordinator(
        api: api,
        discoveryService: _FakePairingDiscoveryService(const <DiscoveredServer>[]),
        sessionConfigRepository: repository,
      );

      final newToken = await coordinator.refreshSession(
        baseUrl: 'http://server:8000',
        accessToken: 'token-1',
        refreshToken: 'refresh-1',
        deviceId: 'device-1',
      );

      expect(newToken, 'token-2');
      expect(repository.savedConfig?.accessToken, 'token-2');
      expect(repository.savedConfig?.refreshToken, 'refresh-1');
    });

    test('refreshSession returns null when refresh fails', () async {
      final api = _FakeMusicApi()..throwOnRefresh = true;
      final repository = _RecordingSessionConfigRepository();
      final coordinator = PairingCoordinator(
        api: api,
        discoveryService: _FakePairingDiscoveryService(const <DiscoveredServer>[]),
        sessionConfigRepository: repository,
      );

      final newToken = await coordinator.refreshSession(
        baseUrl: 'http://server:8000',
        accessToken: 'token-1',
        refreshToken: 'refresh-1',
        deviceId: 'device-1',
      );

      expect(newToken, isNull);
      expect(repository.savedConfig, isNull);
    });

    test('clearExpiredSession clears persisted tokens', () async {
      final repository = _RecordingSessionConfigRepository();
      final coordinator = PairingCoordinator(
        api: _FakeMusicApi(),
        discoveryService: _FakePairingDiscoveryService(const <DiscoveredServer>[]),
        sessionConfigRepository: repository,
      );

      await coordinator.clearExpiredSession();

      expect(repository.clearTokensCalls, 1);
    });
  });
}
