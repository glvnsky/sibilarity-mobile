import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/features/playback/application/playback_volume_sync_coordinator.dart';

class _FakeSystemVolumeBridge implements PlaybackSystemVolumeBridge {
  final StreamController<double> _volumeController =
      StreamController<double>.broadcast();

  @override
  bool isSupported = true;

  double? currentVolume;
  double? appliedVolume;
  final List<double> setCalls = <double>[];

  @override
  Stream<double> get volumeChanges => _volumeController.stream;

  @override
  Future<double?> getCurrentVolumePercent() async => currentVolume;

  @override
  Future<double?> setVolumePercent(double value) async {
    setCalls.add(value);
    return appliedVolume ?? value;
  }

  Future<void> emit(double value) async {
    _volumeController.add(value);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> dispose() => _volumeController.close();
}

void main() {
  group('PlaybackVolumeSyncCoordinator', () {
    test('initialize applies current system volume and listens for changes', () async {
      final bridge = _FakeSystemVolumeBridge()..currentVolume = 35;
      addTearDown(bridge.dispose);

      var localVolume = 50.0;
      final remoteVolumes = <double>[];
      final coordinator = PlaybackVolumeSyncCoordinator(
        systemVolumeBridge: bridge,
        readCurrentVolume: () => localVolume,
        applyLocalVolume: (value) {
          localVolume = value;
        },
        hasServerSession: () => false,
        sendRemoteVolume: (value, {required bool showBusy}) async {
          remoteVolumes.add(value);
        },
      );

      await coordinator.initialize();
      expect(localVolume, 35);

      await bridge.emit(42);

      expect(localVolume, 42);
      expect(remoteVolumes, isEmpty);
    });

    test('system volume changes push remote volume when session is active', () async {
      final bridge = _FakeSystemVolumeBridge();
      addTearDown(bridge.dispose);

      var localVolume = 20.0;
      final sentVolumes = <({double value, bool showBusy})>[];
      final coordinator = PlaybackVolumeSyncCoordinator(
        systemVolumeBridge: bridge,
        readCurrentVolume: () => localVolume,
        applyLocalVolume: (value) {
          localVolume = value;
        },
        hasServerSession: () => true,
        sendRemoteVolume: (value, {required bool showBusy}) async {
          sentVolumes.add((value: value, showBusy: showBusy));
        },
      );

      await coordinator.initialize();
      await bridge.emit(40);

      expect(localVolume, 40);
      expect(sentVolumes, <({double value, bool showBusy})>[
        (value: 40, showBusy: false),
      ]);
    });

    test('syncSystemVolumeFromRemote updates platform volume and local state', () async {
      final bridge = _FakeSystemVolumeBridge()..appliedVolume = 72;
      addTearDown(bridge.dispose);

      var localVolume = 10.0;
      final coordinator = PlaybackVolumeSyncCoordinator(
        systemVolumeBridge: bridge,
        readCurrentVolume: () => localVolume,
        applyLocalVolume: (value) {
          localVolume = value;
        },
        hasServerSession: () => true,
        sendRemoteVolume: (_, {required bool showBusy}) async {},
      );

      final applied = await coordinator.syncSystemVolumeFromRemote(70);

      expect(applied, 72);
      expect(bridge.setCalls, <double>[70]);
      expect(localVolume, 72);
    });

    test('echoed system volume events after local sync do not re-send remotely', () async {
      final bridge = _FakeSystemVolumeBridge();
      addTearDown(bridge.dispose);

      var localVolume = 50.0;
      final sentVolumes = <double>[];
      final coordinator = PlaybackVolumeSyncCoordinator(
        systemVolumeBridge: bridge,
        readCurrentVolume: () => localVolume,
        applyLocalVolume: (value) {
          localVolume = value;
        },
        hasServerSession: () => true,
        sendRemoteVolume: (value, {required bool showBusy}) async {
          sentVolumes.add(value);
        },
      );

      await coordinator.initialize();
      await coordinator.syncSystemVolumeFromRemote(68);
      await bridge.emit(68);

      expect(localVolume, 68);
      expect(sentVolumes, isEmpty);
    });

    test('slider changes debounce local sync to system and remote volume', () async {
      final bridge = _FakeSystemVolumeBridge();
      addTearDown(bridge.dispose);

      var localVolume = 30.0;
      final sentVolumes = <({double value, bool showBusy})>[];
      final coordinator = PlaybackVolumeSyncCoordinator(
        systemVolumeBridge: bridge,
        readCurrentVolume: () => localVolume,
        applyLocalVolume: (value) {
          localVolume = value;
        },
        hasServerSession: () => true,
        sendRemoteVolume: (value, {required bool showBusy}) async {
          sentVolumes.add((value: value, showBusy: showBusy));
        },
        syncDebounce: const Duration(milliseconds: 10),
      );

      // ignore: cascade_invocations
      coordinator.onSliderChanged(80);
      expect(localVolume, 80);
      expect(sentVolumes, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(bridge.setCalls, <double>[80]);
      expect(sentVolumes, <({double value, bool showBusy})>[
        (value: 80, showBusy: false),
      ]);
    });
  });
}
