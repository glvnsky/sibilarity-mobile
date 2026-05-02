import 'dart:async';

import 'package:music_remote_app/core/platform/android_system_volume.dart';

abstract class PlaybackSystemVolumeBridge {
  bool get isSupported;

  Stream<double> get volumeChanges;

  Future<double?> getCurrentVolumePercent();

  Future<double?> setVolumePercent(double value);
}

class AndroidPlaybackSystemVolumeBridge implements PlaybackSystemVolumeBridge {
  @override
  bool get isSupported => AndroidSystemVolume.instance.isSupported;

  @override
  Stream<double> get volumeChanges => AndroidSystemVolume.instance.volumeChanges;

  @override
  Future<double?> getCurrentVolumePercent() =>
      AndroidSystemVolume.instance.getCurrentVolumePercent();

  @override
  Future<double?> setVolumePercent(double value) =>
      AndroidSystemVolume.instance.setVolumePercent(value);
}

class PlaybackVolumeSyncCoordinator {
  PlaybackVolumeSyncCoordinator({
    PlaybackSystemVolumeBridge? systemVolumeBridge,
    required double Function() readCurrentVolume,
    required void Function(double value) applyLocalVolume,
    required bool Function() hasServerSession,
    required Future<void> Function(double value, {required bool showBusy})
    sendRemoteVolume,
    this.systemVolumeTolerance = 5.0,
    this.syncDebounce = const Duration(milliseconds: 75),
  }) : _systemVolumeBridge =
           systemVolumeBridge ?? AndroidPlaybackSystemVolumeBridge(),
       _readCurrentVolume = readCurrentVolume,
       _applyLocalVolume = applyLocalVolume,
       _hasServerSession = hasServerSession,
       _sendRemoteVolume = sendRemoteVolume;

  final PlaybackSystemVolumeBridge _systemVolumeBridge;
  final double Function() _readCurrentVolume;
  final void Function(double value) _applyLocalVolume;
  final bool Function() _hasServerSession;
  final Future<void> Function(double value, {required bool showBusy})
  _sendRemoteVolume;
  final double systemVolumeTolerance;
  final Duration syncDebounce;

  StreamSubscription<double>? _systemVolumeSubscription;
  Timer? _volumeSyncTimer;
  double? _pendingSystemVolume;
  double? _pendingSliderVolumeSync;
  bool _volumeSyncInFlight = false;

  bool get isSupported => _systemVolumeBridge.isSupported;

  Future<void> initialize() async {
    if (!isSupported) {
      return;
    }

    final currentVolume = await _systemVolumeBridge.getCurrentVolumePercent();
    if (currentVolume != null) {
      _applyLocalVolumeIfChanged(currentVolume);
    }

    await _systemVolumeSubscription?.cancel();
    _systemVolumeSubscription = _systemVolumeBridge.volumeChanges.listen(
      (value) => unawaited(_handleSystemVolumeChanged(value)),
    );
  }

  Future<void> dispose() async {
    _volumeSyncTimer?.cancel();
    _volumeSyncTimer = null;
    await _systemVolumeSubscription?.cancel();
    _systemVolumeSubscription = null;
  }

  void onSliderChanged(double value) {
    final nextVolume = _normalizeVolume(value);
    _applyLocalVolumeIfChanged(nextVolume);
    _pendingSliderVolumeSync = nextVolume;
    _volumeSyncTimer?.cancel();
    _volumeSyncTimer = Timer(
      syncDebounce,
      () => unawaited(_flushPendingVolumeSync()),
    );
  }

  Future<void> commitSliderVolume(double value) async {
    _pendingSliderVolumeSync = _normalizeVolume(value);
    await _flushPendingVolumeSync();
  }

  Future<void> sendVolume(
    double value, {
    required bool syncSystemVolume,
    required bool showBusy,
  }) async {
    var nextVolume = _normalizeVolume(value);
    _applyLocalVolumeIfChanged(nextVolume);
    if (syncSystemVolume) {
      final applied = await syncSystemVolumeFromRemote(nextVolume);
      if (applied != null) {
        nextVolume = applied;
      }
    }

    if (!_hasServerSession()) {
      return;
    }

    await _sendRemoteVolume(nextVolume, showBusy: showBusy);
  }

  Future<double?> syncSystemVolumeFromRemote(double value) async {
    if (!isSupported) {
      return null;
    }

    final nextVolume = _normalizeVolume(value);
    _pendingSystemVolume = nextVolume;
    final applied = await _systemVolumeBridge.setVolumePercent(nextVolume);
    if (applied != null) {
      _pendingSystemVolume = applied;
      _applyLocalVolumeIfChanged(applied);
    }
    return applied;
  }

  Future<void> _handleSystemVolumeChanged(double value) async {
    final nextVolume = _normalizeVolume(value);
    final pending = _pendingSystemVolume;
    if (pending != null &&
        (nextVolume - pending).abs() <= systemVolumeTolerance) {
      _pendingSystemVolume = null;
      _applyLocalVolumeIfChanged(nextVolume);
      return;
    }

    _applyLocalVolumeIfChanged(nextVolume);
    if (!_hasServerSession()) {
      return;
    }

    await sendVolume(
      nextVolume,
      syncSystemVolume: false,
      showBusy: false,
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
      await sendVolume(
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

  void _applyLocalVolumeIfChanged(double value) {
    if ((value - _readCurrentVolume()).abs() <= 0.1) {
      return;
    }
    _applyLocalVolume(value);
  }

  double _normalizeVolume(double value) => value.clamp(0, 100).toDouble();
}
