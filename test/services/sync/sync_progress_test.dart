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
}
