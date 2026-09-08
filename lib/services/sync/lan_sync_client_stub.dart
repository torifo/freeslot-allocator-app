import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lan_sync_types.dart';
import 'sync_progress.dart';
import 'sync_settings.dart';

export 'lan_sync_types.dart';

final lanSyncClientProvider = Provider<LanSyncClient>((ref) => LanSyncClient());

/// Web fallback: `dart:io` (and therefore certificate pinning) does not exist
/// in the browser, so every call refuses instead of falling back to an
/// unauthenticated request.
class LanSyncClient {
  LanSyncClient({this.allowInsecureForTest = false, this.timeout = const Duration(seconds: 3)});

  final bool allowInsecureForTest;
  final Duration timeout;

  /// Kept for API parity with the `dart:io` client; nothing on the web ever
  /// reaches a TLS handshake here.
  int certificateChecks = 0;

  static const _unsupported = SyncHttpException(
    0,
    'unsupported',
    'Web 版では LAN 同期は使えません',
  );

  Future<PairResult> pair(
    PairingInfo info, {
    required String deviceId,
    required String deviceName,
  }) async => throw _unsupported;

  Future<Map<String, dynamic>> health(SyncSettings s) async => throw _unsupported;

  Future<Map<String, dynamic>> fetch(SyncSettings s) async => throw _unsupported;

  Future<SyncResponse> sync(
    SyncSettings s,
    Map<String, dynamic> document, {
    String mode = 'merge',
    SyncProgressController? progress,
  }) async => throw _unsupported;
}
