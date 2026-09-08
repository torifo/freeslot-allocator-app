import 'dart:math';

final Random _random = Random.secure();

/// `<prefix>-<microsecondsSinceEpoch>-<device fragment>-<6 random hex chars>`.
///
/// The device fragment is the 4 characters after the platform prefix of the
/// device id (e.g. `android-ab12cd34` → `ab12`), so ids created on different
/// devices never collide even with identical timestamps and random suffixes.
/// Identifiers created by older builds are plain strings and remain valid.
String generateId(String prefix, {String? deviceId}) {
  final micros = DateTime.now().microsecondsSinceEpoch;
  final suffix = List.generate(6, (_) => _random.nextInt(16).toRadixString(16)).join();
  return '$prefix-$micros-${deviceFragment(deviceId)}-$suffix';
}

String deviceFragment(String? deviceId) {
  if (deviceId == null || deviceId.isEmpty) return 'loc0';
  final dash = deviceId.indexOf('-');
  final body = dash >= 0 ? deviceId.substring(dash + 1) : deviceId;
  return body.length >= 4 ? body.substring(0, 4) : body.padRight(4, '0');
}
