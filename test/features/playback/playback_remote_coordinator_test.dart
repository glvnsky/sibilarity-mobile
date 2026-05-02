import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/playback/application/playback_remote_coordinator.dart';

class _FakeMusicApi extends MusicApi {
  bool healthResult = true;
  Map<String, dynamic> stateResult = <String, dynamic>{};
  Map<String, dynamic> positionResult = <String, dynamic>{};
  List<TrackItem> libraryResult = const <TrackItem>[];
  String configuredBaseUrl = '';
  String configuredToken = '';
  String? logoutBaseUrl;
  String? logoutToken;
  final List<({String endpoint, Map<String, dynamic>? body})> commands =
      <({String endpoint, Map<String, dynamic>? body})>[];
  double? seekPosition;

  @override
  void configure({required String baseUrl, required String token}) {
    configuredBaseUrl = baseUrl;
    configuredToken = token;
  }

  @override
  Future<bool> health() async => healthResult;

  @override
  Future<Map<String, dynamic>> state() async => stateResult;

  @override
  Future<Map<String, dynamic>> position() async => positionResult;

  @override
  Future<List<TrackItem>> library({bool forceRescan = false}) async => libraryResult;

  @override
  Future<void> command(String endpoint, {Map<String, dynamic>? body}) async {
    commands.add((endpoint: endpoint, body: body));
  }

  @override
  Future<void> seek(double position) async {
    seekPosition = position;
  }

  @override
  Future<void> logout() async {
    logoutBaseUrl = configuredBaseUrl;
    logoutToken = configuredToken;
  }
}

void main() {
  group('PlaybackRemoteCoordinator', () {
    test('connectAndSync configures api and returns health, state, and library', () async {
      final api = _FakeMusicApi()
        ..healthResult = false
        ..stateResult = <String, dynamic>{'status': 'paused'}
        ..libraryResult = const <TrackItem>[
          TrackItem(id: 'a', title: 'A'),
        ];
      final coordinator = PlaybackRemoteCoordinator(api: api);

      final result = await coordinator.connectAndSync(
        baseUrl: 'http://server:8000',
        accessToken: 'token-1',
      );

      expect(api.configuredBaseUrl, 'http://server:8000');
      expect(api.configuredToken, 'token-1');
      expect(result.health, isFalse);
      expect(result.state, <String, dynamic>{'status': 'paused'});
      expect(result.library.map((track) => track.id), <String>['a']);
    });

    test('refreshState configures api and returns state', () async {
      final api = _FakeMusicApi()
        ..stateResult = <String, dynamic>{'status': 'playing'};
      final coordinator = PlaybackRemoteCoordinator(api: api);

      final state = await coordinator.refreshState(
        baseUrl: 'http://server:8000',
        accessToken: 'token-2',
      );

      expect(api.configuredBaseUrl, 'http://server:8000');
      expect(api.configuredToken, 'token-2');
      expect(state['status'], 'playing');
    });

    test('refreshPosition configures api and returns position', () async {
      final api = _FakeMusicApi()
        ..positionResult = <String, dynamic>{'position': 12.5, 'duration': 99.0};
      final coordinator = PlaybackRemoteCoordinator(api: api);

      final position = await coordinator.refreshPosition(
        baseUrl: 'http://server:8000',
        accessToken: 'token-3',
      );

      expect(position['position'], 12.5);
      expect(position['duration'], 99.0);
    });

    test('sendCommand configures api and sends endpoint payload', () async {
      final api = _FakeMusicApi();
      final coordinator = PlaybackRemoteCoordinator(api: api);

      await coordinator.sendCommand(
        baseUrl: 'http://server:8000',
        accessToken: 'token-4',
        endpoint: '/api/pause',
        body: <String, dynamic>{'foo': 'bar'},
      );

      expect(api.commands.single.endpoint, '/api/pause');
      expect(api.commands.single.body, <String, dynamic>{'foo': 'bar'});
    });

    test('seek configures api and forwards position', () async {
      final api = _FakeMusicApi();
      final coordinator = PlaybackRemoteCoordinator(api: api);

      await coordinator.seek(
        baseUrl: 'http://server:8000',
        accessToken: 'token-5',
        position: 33,
      );

      expect(api.seekPosition, 33);
    });

    test('logout configures api and calls logout', () async {
      final api = _FakeMusicApi();
      final coordinator = PlaybackRemoteCoordinator(api: api);

      await coordinator.logout(
        baseUrl: 'http://server:8000',
        accessToken: 'token-6',
      );

      expect(api.logoutBaseUrl, 'http://server:8000');
      expect(api.logoutToken, 'token-6');
    });
  });
}
