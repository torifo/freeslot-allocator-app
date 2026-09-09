import '../../core/device_clock.dart';
import '../../core/hlc.dart';
import 'sync_document.dart';

/// The highest HLC anywhere in [doc], tombstones and settings included.
///
/// Shared by [SyncService] and the hub-mode store on purpose: a device that
/// missed one of these lists would mint its next edit with a clock the hub has
/// already passed, and that edit would silently lose the next merge.
Hlc highestClockIn(SyncDocument doc) {
  var best = Hlc.migrated;
  void consider(Hlc c) {
    if (c.compareTo(best) > 0) best = c;
  }

  for (final t in doc.taskMaster.tasks) {
    consider(t.meta.clock);
  }
  for (final t in doc.taskMaster.deletedTasks) {
    consider(t.meta.clock);
  }
  for (final c in [
    ...doc.taskMaster.mustDoCategories,
    ...doc.taskMaster.wantToDoCategories,
  ]) {
    consider(c.meta.clock);
  }
  for (final t in [
    ...doc.taskMaster.deletedMustDoCategories,
    ...doc.taskMaster.deletedWantToDoCategories,
  ]) {
    consider(t.meta.clock);
  }
  for (final p in doc.dailyPlan.plans) {
    consider(p.meta.clock);
  }
  for (final s in doc.dailyPlan.slots) {
    consider(s.meta.clock);
  }
  for (final a in doc.dailyPlan.assignments) {
    consider(a.meta.clock);
  }
  for (final t in [
    ...doc.dailyPlan.deletedPlans,
    ...doc.dailyPlan.deletedSlots,
    ...doc.dailyPlan.deletedAssignments,
  ]) {
    consider(t.meta.clock);
  }
  consider(doc.taskMaster.settingsMeta.clock);
  return best;
}

/// Pulls [clock] up to anything [doc] has seen, so the next local edit sorts
/// after the records that just arrived.
Future<void> observeDocumentClocks(DeviceClock clock, SyncDocument doc) async {
  final best = highestClockIn(doc);
  if (!best.isMigrated) await clock.observe(best);
}
