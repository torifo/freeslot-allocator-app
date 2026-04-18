import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../daily_plan/application/daily_plan_controller.dart';
import '../../daily_plan/domain/daily_plan_models.dart';
import '../../task_master/application/task_master_controller.dart';
import '../../task_master/domain/task_models.dart';

class WeeklyReportScreen extends ConsumerStatefulWidget {
  const WeeklyReportScreen({super.key});

  @override
  ConsumerState<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends ConsumerState<WeeklyReportScreen> {
  late DateTime _anchorDate;

  @override
  void initState() {
    super.initState();
    _anchorDate = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(taskMasterControllerProvider);
    final dailyPlanState = ref.watch(dailyPlanControllerProvider);
    final weekStart = _weekStart(_anchorDate);
    final weekEnd = weekStart.add(const Duration(days: 7));

    return Scaffold(
      appBar: AppBar(title: const Text('週次レポート')),
      body: state.when(
        data: (data) => dailyPlanState.when(
          data: (dailyPlanData) {
            final totalEstimateMinutes = data.tasks.fold<int>(
              0,
              (sum, task) => sum + task.estimatedMinutes,
            );
            final weekAssignments = _assignmentsForRange(
              dailyPlanData,
              start: weekStart,
              end: weekEnd,
            );
            final plannedMinutes = weekAssignments.fold<int>(
              0,
              (sum, item) => sum + item.durationMinutes,
            );
            final mustDoMinutes = weekAssignments
                .where((item) => item.taskKind == TaskKind.mustDo)
                .fold<int>(0, (sum, item) => sum + item.durationMinutes);
            final wantToDoMinutes = plannedMinutes - mustDoMinutes;
            final categoryTotals = _categoryTotals(weekAssignments);

            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '集計期間',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${DateFormat('yyyy/MM/dd').format(weekStart)} から ${DateFormat('yyyy/MM/dd').format(weekEnd.subtract(const Duration(days: 1)))}',
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _shiftWeek(-1),
                              icon: const Icon(Icons.chevron_left),
                              label: const Text('前の週'),
                            ),
                            FilledButton.tonal(
                              onPressed: _resetToCurrentWeek,
                              child: const Text('今週'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _shiftWeek(1),
                              icon: const Icon(Icons.chevron_right),
                              label: const Text('次の週'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: const Text('この週の割り当て時間'),
                    subtitle: const Text('DailyPlan に入っている実割り当ての合計'),
                    trailing: Text('$plannedMinutes分'),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: const Text('TaskMaster 見積もり総量'),
                    subtitle: const Text('登録済みタスクの見積もり時間'),
                    trailing: Text('$totalEstimateMinutes分'),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('やるべきこと'),
                        trailing: Text('$mustDoMinutes分'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('やりたいこと'),
                        trailing: Text('$wantToDoMinutes分'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text('カテゴリ別', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (categoryTotals.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('この週の割り当てはまだありません。日次計画で予定を作成すると集計されます。'),
                    ),
                  )
                else
                  ...categoryTotals.entries.map(
                    (entry) => Card(
                      child: ListTile(
                        title: Text(entry.key),
                        trailing: Text('${entry.value}分'),
                      ),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(child: Text(error.toString())),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text(error.toString())),
      ),
    );
  }

  void _shiftWeek(int value) {
    setState(() {
      _anchorDate = _anchorDate.add(Duration(days: 7 * value));
    });
  }

  void _resetToCurrentWeek() {
    setState(() {
      _anchorDate = DateTime.now();
    });
  }

  List<SlotTaskAssignment> _assignmentsForRange(
    DailyPlanStateData data, {
    required DateTime start,
    required DateTime end,
  }) {
    return data.assignments.where((item) {
      return !item.startAt.isBefore(start) && item.startAt.isBefore(end);
    }).toList()..sort((a, b) => a.startAt.compareTo(b.startAt));
  }

  Map<String, int> _categoryTotals(List<SlotTaskAssignment> assignments) {
    final totals = <String, int>{};
    for (final item in assignments) {
      final label = item.categoryName ?? '未分類';
      totals.update(
        label,
        (value) => value + item.durationMinutes,
        ifAbsent: () => item.durationMinutes,
      );
    }

    final entries = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, int>.fromEntries(entries);
  }

  DateTime _weekStart(DateTime anchorDate) {
    final date = DateTime(anchorDate.year, anchorDate.month, anchorDate.day);
    return date.subtract(Duration(days: date.weekday - DateTime.monday));
  }
}
