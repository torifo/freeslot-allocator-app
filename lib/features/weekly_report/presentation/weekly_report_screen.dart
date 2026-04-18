import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../daily_plan/application/daily_plan_controller.dart';
import '../../daily_plan/domain/daily_plan_models.dart';
import '../../task_master/application/task_master_controller.dart';
import '../../task_master/domain/task_models.dart';

class WeeklyReportScreen extends ConsumerWidget {
  const WeeklyReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(taskMasterControllerProvider);
    final dailyPlanState = ref.watch(dailyPlanControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('週次レポート')),
      body: state.when(
        data: (data) => dailyPlanState.when(
          data: (dailyPlanData) {
            final totalEstimateMinutes = data.tasks.fold<int>(
              0,
              (sum, task) => sum + task.estimatedMinutes,
            );
            final weekAssignments = _currentWeekAssignments(dailyPlanData);
            final plannedMinutes = weekAssignments.fold<int>(
              0,
              (sum, item) => sum + item.durationMinutes,
            );
            final mustDoMinutes = weekAssignments
                .where((item) => item.taskKind == TaskKind.mustDo)
                .fold<int>(0, (sum, item) => sum + item.durationMinutes);
            final wantToDoMinutes = plannedMinutes - mustDoMinutes;

            final categoryTotals = <String, int>{};
            for (final item in weekAssignments) {
              final label = item.categoryName ?? '未分類';
              categoryTotals.update(
                label,
                (value) => value + item.durationMinutes,
                ifAbsent: () => item.durationMinutes,
              );
            }

            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Card(
                  child: ListTile(
                    title: const Text('今週の割り当て時間'),
                    subtitle: Text(
                      '${DateFormat('MM/dd').format(_weekStart())} から ${DateFormat('MM/dd').format(_weekEnd())}',
                    ),
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
                      child: Text('今週の割り当てはまだありません。日次計画で予定を作成すると集計されます。'),
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

  List<SlotTaskAssignment> _currentWeekAssignments(DailyPlanStateData data) {
    final start = _weekStart();
    final end = _weekEnd();
    return data.assignments.where((item) {
      return !item.startAt.isBefore(start) && item.startAt.isBefore(end);
    }).toList();
  }

  DateTime _weekStart() {
    final now = DateTime.now();
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - DateTime.monday));
  }

  DateTime _weekEnd() {
    return _weekStart().add(const Duration(days: 7));
  }
}
