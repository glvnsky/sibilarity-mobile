import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/pairing/data/pairing_discovery_service.dart';
import 'package:music_remote_app/features/pairing/data/session_config_repository.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';
import 'package:music_remote_app/features/pairing/domain/models/session_config.dart';

class PairingCoordinator {
  PairingCoordinator({
    required MusicApi api,
    required PairingDiscoveryService discoveryService,
    required SessionConfigRepository sessionConfigRepository,
  }) : _api = api,
       _discoveryService = discoveryService,
       _sessionConfigRepository = sessionConfigRepository;

  final MusicApi _api;
  final PairingDiscoveryService _discoveryService;
  final SessionConfigRepository _sessionConfigRepository;

  Future<List<DiscoveredServer>> discoverServers() =>
      _discoveryService.discoverServers();

  Future<SessionConfig?> pairAndPersistSession({
    required String baseUrl,
    required String currentToken,
    required String deviceId,
    required Future<String?> Function(String pairingId) requestPairingCode,
    String deviceName = 'Flutter Phone',
  }) async {
    _api.configure(baseUrl: baseUrl, token: currentToken);
    final start = await _api.pairingStart(
      deviceId: deviceId,
      deviceName: deviceName,
    );
    final code = await requestPairingCode(start.pairingId);
    if (code == null) {
      return null;
    }
    final confirm = await _api.pairingConfirm(
      pairingId: start.pairingId,
      code: code,
    );
    final config = SessionConfig(
      baseUrl: baseUrl,
      accessToken: confirm.accessToken,
      refreshToken: confirm.refreshToken,
      deviceId: deviceId,
    );
    await _sessionConfigRepository.save(config);
    return config;
  }

  Future<String?> refreshSession({
    required String baseUrl,
    required String accessToken,
    required String refreshToken,
    required String deviceId,
  }) async {
    if (baseUrl.isEmpty || refreshToken.isEmpty) {
      return null;
    }
    try {
      _api.configure(baseUrl: baseUrl, token: accessToken);
      final newToken = await _api.refreshAccessToken(refreshToken);
      await _sessionConfigRepository.save(
        SessionConfig(
          baseUrl: baseUrl,
          accessToken: newToken,
          refreshToken: refreshToken,
          deviceId: deviceId,
        ),
      );
      return newToken;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearExpiredSession() => _sessionConfigRepository.clearTokens();
}
