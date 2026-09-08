import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/core/tombstone.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_merger.dart';

/// Applies random add/edit/delete operations on two replicas, syncs them in
/// random order three times, and asserts both replicas end identical.
void main() {
  test('random operation sequences converge', () {
    for (var seed = 0; seed < 50; seed += 1) {
      final random = Random(seed);
      var a = _empty('a');
      var b = _empty('b');
      final clockA = HlcClock(
        deviceId: 'a',
        now: () => 1000 + random.nextInt(50),
      );
      final clockB = HlcClock(
        deviceId: 'b',
        now: () => 1000 + random.nextInt(50),
      );
      for (var step = 0; step < 20; step += 1) {
        if (random.nextBool()) {
          a = _mutate(a, clockA, random);
        } else {
          b = _mutate(b, clockB, random);
        }
        if (random.nextInt(4) == 0) {
          final merged = SyncMerger.merge(a, b).document;
          a = merged;
          b = merged;
          clockA.observe(_maxClock(merged));
          clockB.observe(_maxClock(merged));
        }
      }
      for (var round = 0; round < 3; round += 1) {
        final merged = random.nextBool()
            ? SyncMerger.merge(a, b)
            : SyncMerger.merge(b, a);
        a = merged.document;
        b = merged.document;
      }
      expect(a.toJson()['taskMaster'], b.toJson()['taskMaster'], reason: 'seed $seed');
    }
  });

  test('one merge already converges both orders', () {
    for (var seed = 0; seed < 50; seed += 1) {
      final random = Random(seed);
      var a = _empty('a');
      var b = _empty('b');
      final clockA = HlcClock(deviceId: 'a', now: () => 1000 + random.nextInt(50));
      final clockB = HlcClock(deviceId: 'b', now: () => 1000 + random.nextInt(50));
      for (var step = 0; step < 20; step += 1) {
        if (random.nextBool()) {
          a = _mutate(a, clockA, random);
        } else {
          b = _mutate(b, clockB, random);
        }
      }
      final ab = SyncMerger.merge(a, b).document;
      final ba = SyncMerger.merge(b, a).document;
      expect(
        ab.toJson()['taskMaster'],
        ba.toJson()['taskMaster'],
        reason: 'commutative, seed $seed',
      );
      expect(
        SyncMerger.merge(ab, b).document.toJson()['taskMaster'],
        ab.toJson()['taskMaster'],
        reason: 'idempotent, seed $seed',
      );
    }
  });
}

SyncDocument _empty(String device) => SyncDocument(
  exportedAt: DateTime.utc(2026),
  deviceId: device,
  taskMaster: TaskMasterStateData(
    tasks: const <TaskMaster>[],
    mustDoCategories: const <TaskCategory>[],
    wantToDoCategories: const <TaskCategory>[],
    shareCategories: false,
  ),
  dailyPlan: DailyPlanStateData.initial(),
);

SyncDocument _mutate(SyncDocument doc, HlcClock clock, Random random) {
  final tasks = List<TaskMaster>.from(doc.taskMaster.tasks);
  var dead = List<Tombstone>.from(doc.taskMaster.deletedTasks);
  final now = DateTime.utc(2026, 1, 1, 0, 0, clock.last.counter);
  final op = random.nextInt(3);
  if (op == 0 || tasks.isEmpty) {
    tasks.add(
      TaskMaster(
        id: 't${random.nextInt(8)}-${clock.deviceId}',
        title: 'x${random.nextInt(100)}',
        kind: TaskKind.mustDo,
        priority: 3,
        createdAt: now,
        updatedAt: now,
        meta: SyncMeta.stamp(clock.next(), now),
      ),
    );
  } else if (op == 1) {
    final i = random.nextInt(tasks.length);
    tasks[i] = tasks[i].copyWith(
      title: 'y${random.nextInt(100)}',
      meta: tasks[i].meta.touch(clock.next(), now),
    );
  } else {
    final removed = tasks.removeAt(random.nextInt(tasks.length));
    dead.add(
      Tombstone(id: removed.id, meta: removed.meta.tombstone(clock.next(), now)),
    );
  }
  final seen = <String>{};
  tasks.retainWhere((t) => seen.add(t.id));
  // Re-adding a tombstoned id retires its tombstone locally, exactly as the
  // controller does; a peer that still holds the tombstone lets merge decide.
  dead = withoutTombstonesFor(dead, tasks.map((t) => t.id));
  return SyncDocument(
    exportedAt: doc.exportedAt,
    deviceId: doc.deviceId,
    taskMaster: doc.taskMaster.copyWith(tasks: tasks, deletedTasks: dead),
    dailyPlan: doc.dailyPlan,
  );
}

Hlc _maxClock(SyncDocument doc) {
  var best = Hlc.migrated;
  for (final t in doc.taskMaster.tasks) {
    if (t.meta.clock.compareTo(best) > 0) best = t.meta.clock;
  }
  for (final t in doc.taskMaster.deletedTasks) {
    if (t.meta.clock.compareTo(best) > 0) best = t.meta.clock;
  }
  return best;
}
