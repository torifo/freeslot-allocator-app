import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_progress.dart';

void main() {
  test('advances stages, tracks bytes and elapsed, and flags slow stages', () {
    var now = DateTime.utc(2026, 1, 1);
    final c = SyncProgressController(now: () => now);
    c.start(SyncKind.lan);
    expect(c.value.stage, SyncStage.connecting);
    c.stage(SyncStage.sending, totalBytes: 1000);
    c.bytes(400);
    expect(c.value.sentBytes, 400);
    expect(c.value.fraction, closeTo(0.4, 0.001));
    now = now.add(const Duration(seconds: 11));
    expect(c.value.elapsed(now).inSeconds, 11);
    expect(c.value.isSlow(now), isTrue);
    c.stage(SyncStage.applying);
    c.finish(const SyncSummary(added: 1, updated: 2, deleted: 0, warnings: 0));
    expect(c.value.stage, SyncStage.done);
    expect(c.value.summary?.updated, 2);
  });

  test('cancel before send completes is clean; after send is flagged', () {
    final c = SyncProgressController();
    c.start(SyncKind.lan);
    c.stage(SyncStage.sending);
    c.cancel();
    expect(c.value.stage, SyncStage.cancelled);
    expect(c.value.hubMayHaveChanged, isFalse);
    c.start(SyncKind.lan);
    c.stage(SyncStage.waitingHub);
    c.cancel();
    expect(c.value.hubMayHaveChanged, isTrue);
    expect(c.isCancelled, isTrue);
  });

  test('fail records the error code', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    c.fail('unreachable', 'PC が見つかりません');
    expect(c.value.stage, SyncStage.failed);
    expect(c.value.errorCode, 'unreachable');
  });

  test('qr frames progress', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    c.frames(received: 3, total: 10, missing: [0, 4, 5, 6, 7, 8, 9]);
    expect(c.value.fraction, closeTo(0.3, 0.001));
    expect(c.value.missingFrames, hasLength(7));
  });

  test('cancel during a QR scan does not claim the hub may have changed', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    c.stage(SyncStage.scanning);
    c.cancel();
    expect(c.value.stage, SyncStage.cancelled);
    expect(
      c.value.hubMayHaveChanged,
      isFalse,
      reason: 'scanning sorts after waitingHub in the enum but never touches the hub',
    );
    c.start(SyncKind.qr);
    c.stage(SyncStage.applying);
    c.cancel();
    expect(c.value.hubMayHaveChanged, isFalse, reason: 'a QR transfer has no hub to change');
  });

  test('cancelling a finished sync is a no-op', () {
    final c = SyncProgressController();
    c.start(SyncKind.lan);
    c.stage(SyncStage.waitingHub);
    c.finish(const SyncSummary(added: 1, updated: 0, deleted: 0, warnings: 0));
    c.cancel();
    expect(c.value.stage, SyncStage.done);
    expect(c.value.summary?.added, 1);
    expect(c.isCancelled, isFalse);
  });

  test('cancelling a failed sync keeps the error', () {
    final c = SyncProgressController();
    c.start(SyncKind.lan);
    c.fail('unreachable', 'PC が見つかりません');
    c.cancel();
    expect(c.value.stage, SyncStage.failed);
    expect(c.value.errorCode, 'unreachable');
  });

  test('a finished QR transfer reads as complete even with frames unscanned', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    c.frames(received: 8, total: 10, missing: [8, 9]);
    expect(c.value.fraction, closeTo(0.8, 0.001));
    c.finish(const SyncSummary(added: 0, updated: 0, deleted: 0, warnings: 0));
    expect(c.value.fraction, 1);
  });

  test('re-entering sending restarts the byte count', () {
    final c = SyncProgressController();
    c.start(SyncKind.lan);
    c.stage(SyncStage.sending, totalBytes: 1000);
    c.bytes(700);
    c.stage(SyncStage.connecting);
    c.stage(SyncStage.sending, totalBytes: 1000);
    expect(c.value.sentBytes, 0);
    expect(c.value.fraction, 0);
  });

  test('missingFrames cannot be mutated after it is published', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    final source = <int>[1, 2];
    c.frames(received: 1, total: 3, missing: source);
    expect(() => c.value.missingFrames.add(3), throwsUnsupportedError);
    source.add(3);
    expect(c.value.missingFrames, [1, 2], reason: 'the published value is a copy');
  });

  test('copyWith can clear the error and the summary', () {
    final c = SyncProgressController();
    c.start(SyncKind.lan);
    c.finish(const SyncSummary(added: 1, updated: 0, deleted: 0, warnings: 0));
    c.fail('timeout', '応答がありません');
    expect(c.value.copyWith(clearError: true).errorCode, isNull);
    expect(c.value.copyWith(clearError: true).errorMessage, isNull);
    expect(c.value.copyWith(clearSummary: true).summary, isNull);
  });
}
