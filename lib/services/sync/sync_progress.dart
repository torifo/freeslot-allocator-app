import 'package:flutter/foundation.dart';

enum SyncKind { lan, qr, file }

enum SyncStage {
  idle,
  connecting,
  sending,
  waitingHub,
  receiving,
  applying,
  saving,
  done,
  cancelled,
  failed,
  scanning,
  decoding,
}

class SyncSummary {
  const SyncSummary({
    required this.added,
    required this.updated,
    required this.deleted,
    required this.warnings,
    this.removed = 0,
  });

  final int added;
  final int updated;
  final int deleted;
  final int warnings;

  /// Records the hub dropped entirely (purged tombstones), as opposed to the
  /// [deleted] ones that are still carried as tombstones.
  final int removed;

  factory SyncSummary.fromJson(Map<String, dynamic> j) => SyncSummary(
    added: j['added'] as int? ?? 0,
    updated: j['updated'] as int? ?? 0,
    deleted: j['deleted'] as int? ?? 0,
    warnings: j['warnings'] as int? ?? 0,
    removed: j['removed'] as int? ?? 0,
  );
}

/// Immutable snapshot the UI renders. Only measurable stages carry numbers.
class SyncProgress {
  SyncProgress({
    required this.kind,
    required this.stage,
    required this.startedAt,
    this.stageStartedAt,
    this.sentBytes = 0,
    this.totalBytes,
    this.receivedBytes = 0,
    this.framesReceived = 0,
    this.framesTotal = 0,
    this.summary,
    this.errorCode,
    this.errorMessage,
    this.hubMayHaveChanged = false,
    List<int> missingFrames = const <int>[],
  }) : missingFrames = List<int>.unmodifiable(missingFrames);

  final SyncKind kind;
  final SyncStage stage;
  final DateTime startedAt;
  final DateTime? stageStartedAt;
  final int sentBytes;
  final int? totalBytes;
  final int receivedBytes;
  final int framesReceived;
  final int framesTotal;
  /// Unmodifiable: the panel rebuilds from this list, and a caller mutating
  /// it in place would change a value that has already been published.
  final List<int> missingFrames;
  final SyncSummary? summary;
  final String? errorCode;
  final String? errorMessage;

  /// True when cancel happened after the request was fully sent: the hub may already hold the merge.
  final bool hubMayHaveChanged;

  static const slowAfter = Duration(seconds: 10);

  Duration elapsed(DateTime now) => now.difference(startedAt);

  bool isSlow(DateTime now) =>
      stage != SyncStage.done &&
      stage != SyncStage.failed &&
      stage != SyncStage.cancelled &&
      elapsed(now) > slowAfter;

  double? get fraction {
    // A finished sync is 100%, whatever the last frame count said: a QR
    // transfer that ends with a couple of frames never re-scanned (because
    // the document was already complete) must not leave the bar short.
    if (stage == SyncStage.done) return 1;
    if (stage == SyncStage.sending && totalBytes != null && totalBytes! > 0) {
      return sentBytes / totalBytes!;
    }
    if (kind == SyncKind.qr && framesTotal > 0) return framesReceived / framesTotal;
    return null; // indeterminate (e.g. waitingHub)
  }

  bool get isActive =>
      stage != SyncStage.idle &&
      stage != SyncStage.done &&
      stage != SyncStage.failed &&
      stage != SyncStage.cancelled;

  SyncProgress copyWith({
    SyncStage? stage,
    DateTime? stageStartedAt,
    int? sentBytes,
    int? totalBytes,
    int? receivedBytes,
    int? framesReceived,
    int? framesTotal,
    List<int>? missingFrames,
    SyncSummary? summary,
    String? errorCode,
    String? errorMessage,
    bool? hubMayHaveChanged,
    bool clearError = false,
    bool clearSummary = false,
  }) => SyncProgress(
    kind: kind,
    stage: stage ?? this.stage,
    startedAt: startedAt,
    stageStartedAt: stageStartedAt ?? this.stageStartedAt,
    sentBytes: sentBytes ?? this.sentBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    framesReceived: framesReceived ?? this.framesReceived,
    framesTotal: framesTotal ?? this.framesTotal,
    missingFrames: missingFrames ?? this.missingFrames,
    summary: clearSummary ? null : (summary ?? this.summary),
    errorCode: clearError ? null : (errorCode ?? this.errorCode),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    hubMayHaveChanged: hubMayHaveChanged ?? this.hubMayHaveChanged,
  );
}

class SyncProgressController extends ValueNotifier<SyncProgress> {
  SyncProgressController({DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc()),
      super(
        SyncProgress(
          kind: SyncKind.lan,
          stage: SyncStage.idle,
          startedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
      );

  final DateTime Function() _now;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  void start(SyncKind kind) {
    _cancelled = false;
    value = SyncProgress(
      kind: kind,
      stage: SyncStage.connecting,
      startedAt: _now(),
      stageStartedAt: _now(),
    );
  }

  void stage(SyncStage s, {int? totalBytes}) => value = value.copyWith(
    stage: s,
    stageStartedAt: _now(),
    totalBytes: totalBytes,
    // Entering `sending` starts a new upload — a retry after a failed attempt
    // must not begin with the previous attempt's byte count already on the bar.
    sentBytes: s == SyncStage.sending ? 0 : null,
  );

  void bytes(int sent) => value = value.copyWith(sentBytes: sent);

  void received(int bytes) => value = value.copyWith(receivedBytes: bytes);

  void frames({required int received, required int total, required List<int> missing}) =>
      value = value.copyWith(framesReceived: received, framesTotal: total, missingFrames: missing);

  void finish(SyncSummary summary) =>
      value = value.copyWith(stage: SyncStage.done, summary: summary, stageStartedAt: _now());

  void fail(String code, String message) =>
      value = value.copyWith(
        stage: SyncStage.failed,
        errorCode: code,
        errorMessage: message,
        stageStartedAt: _now(),
      );

  /// The stages that only exist once a LAN request has been fully handed to
  /// the hub. Cancelling in any of them means the hub may already hold the
  /// merge, so the UI has to warn that the two sides can now differ.
  ///
  /// Spelled out rather than compared by [SyncStage] index: the enum is
  /// ordered for reading, not for meaning, and `scanning` / `decoding` sit
  /// past `waitingHub` in it while belonging to a QR transfer that never
  /// touched the hub at all.
  static const _afterHandoff = <SyncStage>{
    SyncStage.waitingHub,
    SyncStage.receiving,
    SyncStage.applying,
    SyncStage.saving,
  };

  void cancel() {
    // Cancelling something already finished, failed or cancelled must not
    // rewrite its outcome: the panel would lose the summary it is showing.
    if (!value.isActive) return;
    _cancelled = true;
    final after = value.kind == SyncKind.lan && _afterHandoff.contains(value.stage);
    value = value.copyWith(
      stage: SyncStage.cancelled,
      hubMayHaveChanged: after,
      stageStartedAt: _now(),
    );
  }
}
