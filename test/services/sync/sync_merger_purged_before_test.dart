import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_merger.dart';

/// Dart-only: the shared cross-language fixtures under `test/fixtures/sync_merge`
/// all use `Z`, so they cannot catch an offset-aware regression here.
SyncDocument doc(String deviceId, String? purgedBefore) => SyncDocument.fromJson(<String, dynamic>{
  'version': 2,
  'exportedAt': '2026-02-01T00:00:00.000Z',
  'deviceId': deviceId,
  'purgedBefore': purgedBefore,
  'taskMaster': <String, dynamic>{},
  'dailyPlan': <String, dynamic>{},
});

void main() {
  test('purgedBefore is the later instant, not the larger string', () {
    // 09:00+09:00 is 00:00Z — earlier than 05:00Z, but larger as text.
    final offset = doc('a', '2026-01-01T09:00:00+09:00');
    final utc = doc('b', '2026-01-01T05:00:00.000Z');
    final expected = DateTime.utc(2026, 1, 1, 5);

    expect(SyncMerger.merge(offset, utc).document.purgedBefore, expected);
    expect(SyncMerger.merge(utc, offset).document.purgedBefore, expected);
  });

  test('the adopted purgedBefore is written back as UTC ISO with Z', () {
    final merged = SyncMerger.merge(
      doc('a', '2026-01-01T09:00:00+09:00'),
      doc('b', null),
    ).document;
    expect(merged.purgedBefore, DateTime.utc(2026, 1, 1));
    expect(merged.toJson()['purgedBefore'], '2026-01-01T00:00:00.000Z');
  });

  test('a missing purgedBefore never overrides one that is set', () {
    expect(
      SyncMerger.merge(doc('a', null), doc('b', '2026-03-01T00:00:00.000Z')).document.purgedBefore,
      DateTime.utc(2026, 3),
    );
    expect(SyncMerger.merge(doc('a', null), doc('b', null)).document.purgedBefore, isNull);
  });
}
