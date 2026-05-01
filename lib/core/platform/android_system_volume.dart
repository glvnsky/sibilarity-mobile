import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidSystemVolume {
  AndroidSystemVolume._();

  static final AndroidSystemVolume instance = AndroidSystemVolume._();

  static const _methodChannel = MethodChannel(
    'music_remote_app/system_volume',
  );
  static const _eventChannel = EventChannel(
    'music_remote_app/system_volume/events',
  );

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Stream<double> get volumeChanges {
    if (!isSupported) {
      return const Stream<double>.empty();
    }
    return _eventChannel.receiveBroadcastStream().map((event) {
      if (event is num) {
        return event.toDouble().clamp(0, 100).toDouble();
      }
      return 0.0;
    });
  }

  Future<double?> getCurrentVolumePercent() async {
    if (!isSupported) {
      return null;
    }
    final value = await _methodChannel.invokeMethod<num>('getVolumePercent');
    return value?.toDouble().clamp(0, 100).toDouble();
  }

  Future<double?> setVolumePercent(double value) async {
    if (!isSupported) {
      return null;
    }
    final applied = await _methodChannel.invokeMethod<num>(
      'setVolumePercent',
      {'value': value.clamp(0, 100).toDouble()},
    );
    return applied?.toDouble().clamp(0, 100).toDouble();
  }
}
