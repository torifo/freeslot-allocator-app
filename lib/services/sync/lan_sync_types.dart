import 'sync_progress.dart';

/// A failed exchange with the hub.
///
/// [status] is the HTTP status, or 0 when the request never produced one
/// (no route to the host, TLS mismatch, timeout, cancel).
class SyncHttpException implements Exception {
  const SyncHttpException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  /// True when trying again unchanged could plausibly succeed.
  ///
  /// Transport failures are retriable; anything the hub answered with is a
  /// decision about *this* payload, so repeating it only wastes the battery.
  /// 413 in particular must never be retried: the hub closes the connection
  /// without draining the body, so a retry loop would hammer a fresh socket
  /// per attempt with the same over-sized document.
  bool get retriable => status == 0 && (code == 'unreachable' || code == 'timeout');

  @override
  String toString() => 'SyncHttpException($status $code): $message';
}

class PairResult {
  const PairResult({
    required this.token,
    required this.hubDeviceId,
    required this.fingerprint,
  });

  final String token;
  final String hubDeviceId;
  final String fingerprint;
}

class SyncResponse {
  const SyncResponse({
    required this.document,
    required this.summary,
    required this.warnings,
  });

  final Map<String, dynamic> document;
  final SyncSummary summary;
  final List<String> warnings;
}

/// Compares two SHA-256 fingerprints, tolerating case and `AB:CD:…` grouping.
///
/// The comparison walks the whole string even after a mismatch so the time it
/// takes does not leak where the first differing byte is.
bool fingerprintMatches({required String sha256Hex, required String expected}) {
  final a = _normalizeFingerprint(sha256Hex);
  final b = _normalizeFingerprint(expected);
  if (a.isEmpty || b.isEmpty || a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

String _normalizeFingerprint(String value) =>
    value.replaceAll(RegExp(r'[\s:]'), '').toUpperCase();

/// User-facing Japanese text for an error code from the hub or the transport.
///
/// The hub's own `message` is English and meant for logs, so every code the
/// hub can return gets a sentence that says what the person should do next.
String syncErrorMessage(String code, {String? fallback}) => switch (code) {
  'not_paired' =>
    'PC とペアリングされていません。設定の「PC とペアリング」から QR を読み取ってください。',
  'unauthorized' =>
    'PC がこの端末を認識できませんでした。もう一度ペアリングしてください。',
  'pairing_failed' => 'ペアリングコードが違います。PC の画面の QR を読み直してください。',
  'pairing_code_expired' =>
    'ペアリングコードの有効期限が切れています。PC で新しい QR を表示してください。',
  'too_many_attempts' =>
    '失敗が続いたためペアリングが止められました。PC で新しい QR を表示してください。',
  'purged_before' =>
    'PC 側で古い削除履歴が掃除されています。どちらのデータを正にするか選んでください。',
  'upgrade_required' => 'アプリが古いため同期できません。アプリを更新してください。',
  'unsupported_version' =>
    'PC 側のハブが古いため同期できません。PC のハブを更新してください。',
  'invalid_document' =>
    'この端末のデータを PC が読めませんでした。アプリを更新しても直らない場合はサポートへご連絡ください。',
  'bad_timestamp' =>
    '同期時刻の記録が壊れています。ペアリングをやり直すと直ります。',
  'payload_too_large' =>
    'データが大きすぎて送れませんでした。不要なタスクを整理するか、QR かファイルで渡してください。',
  'certificate' => 'PC の証明書が変わっています。もう一度ペアリングしてください。',
  'unreachable' =>
    'PC に接続できません。同じ Wi-Fi に接続されているか確認するか、QR で連携してください。',
  'timeout' => 'PC からの応答がありません。しばらくしてからもう一度お試しください。',
  'cancelled' => '同期を中止しました。',
  'corrupt' => 'PC から受け取ったデータを読めませんでした。',
  'unsupported' => 'この環境では LAN 同期は使えません。',
  _ => fallback ?? '同期に失敗しました（$code）。',
};
