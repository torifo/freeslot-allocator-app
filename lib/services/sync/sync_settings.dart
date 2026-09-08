import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final syncSettingsStoreProvider = Provider<SyncSettingsStore>((ref) => SyncSettingsStore());

/// What the phone remembers about its paired hub.
///
/// Stored in shared_preferences in plain text (app-sandboxed, on-device only).
class SyncSettings {
  const SyncSettings({
    this.host,
    this.port = 47820,
    this.fingerprint,
    this.token,
    this.hubDeviceId,
    this.deviceName = '',
    this.lastSyncAt,
  });

  final String? host;
  final int port;
  final String? fingerprint;
  final String? token;
  final String? hubDeviceId;
  final String deviceName;
  final DateTime? lastSyncAt;

  bool get isPaired => host != null && fingerprint != null && token != null;
  String get baseUrl => 'https://$host:$port';

  SyncSettings copyWith({
    String? host,
    int? port,
    String? fingerprint,
    String? token,
    String? hubDeviceId,
    String? deviceName,
    DateTime? lastSyncAt,
    bool clearLastSync = false,
  }) => SyncSettings(
    host: host ?? this.host,
    port: port ?? this.port,
    fingerprint: fingerprint ?? this.fingerprint,
    token: token ?? this.token,
    hubDeviceId: hubDeviceId ?? this.hubDeviceId,
    deviceName: deviceName ?? this.deviceName,
    lastSyncAt: clearLastSync ? null : (lastSyncAt ?? this.lastSyncAt),
  );
}

/// Parsed `frelocator://pair?host=…&port=…&fp=…&code=…`.
class PairingInfo {
  const PairingInfo({
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.code,
  });

  final String host;
  final int port;
  final String fingerprint;
  final String code;

  static PairingInfo parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'frelocator' || uri.host != 'pair') {
      throw const FormatException('ペアリング用の QR ではありません');
    }
    final q = uri.queryParameters;
    final host = q['host'] ?? '';
    final port = int.tryParse(q['port'] ?? '');
    final fp = (q['fp'] ?? '').toUpperCase();
    final code = q['code'] ?? '';
    // A port outside 1..65535 cannot be dialled; `int.tryParse` happily
    // accepts `0` and `999999`, so the range is checked here rather than
    // failing later as an opaque socket error.
    if (host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[0-9A-F]{64}$').hasMatch(fp) ||
        code.isEmpty) {
      throw const FormatException('ペアリング情報が不完全です');
    }
    return PairingInfo(host: host, port: port, fingerprint: fp, code: code);
  }
}

class SyncSettingsStore {
  static const _k = 'sync_settings_v1';

  Future<SyncSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final host = p.getString('$_k.host');
    return SyncSettings(
      host: host,
      port: p.getInt('$_k.port') ?? 47820,
      fingerprint: p.getString('$_k.fp'),
      token: p.getString('$_k.token'),
      hubDeviceId: p.getString('$_k.hub'),
      deviceName: p.getString('$_k.name') ?? '',
      lastSyncAt: DateTime.tryParse(p.getString('$_k.lastSyncAt') ?? '')?.toUtc(),
    );
  }

  Future<void> save(SyncSettings s) async {
    final p = await SharedPreferences.getInstance();
    Future<void> put(String key, String? v) =>
        v == null ? p.remove('$_k.$key') : p.setString('$_k.$key', v);
    await put('host', s.host);
    await p.setInt('$_k.port', s.port);
    await put('fp', s.fingerprint);
    await put('token', s.token);
    await put('hub', s.hubDeviceId);
    await put('name', s.deviceName);
    await put('lastSyncAt', s.lastSyncAt?.toUtc().toIso8601String());
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final key in ['host', 'port', 'fp', 'token', 'hub', 'name', 'lastSyncAt']) {
      await p.remove('$_k.$key');
    }
  }
}
