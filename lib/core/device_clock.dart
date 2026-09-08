import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hlc.dart';

/// Loaded once at startup; use `ref.read(deviceClockProvider)` afterwards.
final deviceClockProvider = Provider<DeviceClock>((ref) {
  throw UnimplementedError('deviceClockProvider must be overridden in main()');
});

/// Owns this device's identity and its hybrid logical clock, persisting both.
class DeviceClock {
  DeviceClock._(this._prefs, this.deviceId, this._clock);

  static const _deviceIdKey = 'sync_device_id';
  static const _lastClockKey = 'sync_last_clock';

  final SharedPreferences _prefs;
  final String deviceId;
  final HlcClock _clock;

  static String defaultPlatformPrefix() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    return 'other';
  }

  static Future<DeviceClock> load({String? platformPrefix, int Function()? now}) async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      final random = Random.secure();
      final suffix = List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
      deviceId = '${platformPrefix ?? defaultPlatformPrefix()}-$suffix';
      await prefs.setString(_deviceIdKey, deviceId);
    }
    final last = Hlc.tryParse(prefs.getString(_lastClockKey));
    return DeviceClock._(prefs, deviceId, HlcClock(deviceId: deviceId, now: now, last: last));
  }

  Future<Hlc> next() async {
    final value = _clock.next();
    await _prefs.setString(_lastClockKey, value.toString());
    return value;
  }

  Future<void> observe(Hlc remote) async {
    _clock.observe(remote);
    await _prefs.setString(_lastClockKey, _clock.last.toString());
  }
}
