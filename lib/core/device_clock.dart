import 'dart:math';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, debugPrint, kIsWeb;
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

  /// Chains persistence writes so a slower write can never clobber a faster
  /// one with a smaller value; see [next] and [observe].
  Future<void> _persistChain = Future.value();

  static String defaultPlatformPrefix() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'other';
    }
  }

  /// [deviceId] forces the identity instead of minting or reading one.
  ///
  /// Hub mode passes `web-<webId>`: the browser's records have to carry the
  /// same device id the store pushes, or the hub attributes this tab's edits to
  /// a device that never sent anything. It is derived from the web id the
  /// browser already persists, so it is deliberately *not* stored again — a
  /// second copy could only ever disagree with the first.
  static Future<DeviceClock> load({
    String? platformPrefix,
    String? deviceId,
    int Function()? now,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (deviceId != null && deviceId.isNotEmpty) {
      final last = Hlc.tryParse(prefs.getString(_lastClockKey));
      return DeviceClock._(prefs, deviceId, HlcClock(deviceId: deviceId, now: now, last: last));
    }
    deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      final random = Random.secure();
      final suffix = List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
      deviceId = '${platformPrefix ?? defaultPlatformPrefix()}-$suffix';
      final ok = await prefs.setString(_deviceIdKey, deviceId);
      if (!ok) {
        // Fatal: without a persisted device id, a restart would mint a new
        // identity and desync this device's HLC history from the hub.
        throw StateError('Failed to persist $_deviceIdKey');
      }
    }
    final last = Hlc.tryParse(prefs.getString(_lastClockKey));
    return DeviceClock._(prefs, deviceId, HlcClock(deviceId: deviceId, now: now, last: last));
  }

  Future<Hlc> next() async {
    final value = _clock.next();
    await _persist(value);
    return value;
  }

  Future<void> observe(Hlc remote) async {
    _clock.observe(remote);
    await _persist(_clock.last);
  }

  /// Chains [value]'s write onto any writes already in flight, so writes
  /// complete in issue order and a later (larger) value can never be
  /// overwritten by an earlier (smaller) one that was still persisting.
  Future<void> _persist(Hlc value) {
    final chained = _persistChain.then((_) async {
      final storedRaw = _prefs.getString(_lastClockKey);
      final stored = Hlc.tryParse(storedRaw);
      if (stored != null && stored.compareTo(value) >= 0) {
        return;
      }
      final ok = await _prefs.setString(_lastClockKey, value.toString());
      if (!ok) {
        debugPrint('DeviceClock: failed to persist $_lastClockKey');
      }
    });
    _persistChain = chained.catchError((_) {});
    return chained;
  }
}
