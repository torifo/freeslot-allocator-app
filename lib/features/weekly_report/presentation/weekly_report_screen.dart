import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/error_view.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../application/weekly_report_logic.dart';
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
    final currentWeekStart = weekStart(_anchorDate);
    final weekEnd = currentWeekStart.add(const Duration(days: 7));

    return Scaffold(
      appBar: AppBar(title: const Text('週次レポート')),
      body: state.when(
        data: (data) => dailyPlanState.when(
          data: (dailyPlanData) {
            final currentCategories = data.shareCategories
                ? data.mustDoCategories
                : <TaskCategory>[
                    ...data.mustDoCategories,
                    ...data.wantToDoCategories,
                  ];
            final weekAssignments = assignmentsOverlappingRange(
              dailyPlanData.assignments,
              start: currentWeekStart,
              end: weekEnd,
            );
            final totalEstimateMinutes = estimatedMinutesForAssignments(
              weekAssignments,
              data.tasks,
            );
            final plannedMinutes = totalAssignedMinutes(
              weekAssignments,
              start: currentWeekStart,
              end: weekEnd,
            );
            final mustDoMinutes = totalAssignedMinutes(
              weekAssignments.where((item) => item.taskKind == TaskKind.mustDo),
              start: currentWeekStart,
              end: weekEnd,
            );
            final wantToDoMinutes = plannedMinutes - mustDoMinutes;
            final resolvedCategoryTotals = categoryTotals(
              weekAssignments,
              start: currentWeekStart,
              end: weekEnd,
              tasks: data.tasks,
              categories: currentCategories,
            );

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
                          '${DateFormat('yyyy/MM/dd').format(currentWeekStart)} から ${DateFormat('yyyy/MM/dd').format(weekEnd.subtract(const Duration(days: 1)))}',
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
                    subtitle: const Text('この週に割り当てた予定の見積もり合計'),
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
                if (resolvedCategoryTotals.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('この週の割り当てはまだありません。日次計画で予定を作成すると集計されます。'),
                    ),
                  )
                else
                  ...resolvedCategoryTotals.entries.map(
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
          error: (error, stackTrace) => ErrorView(
            onRetry: () => ref.invalidate(dailyPlanControllerProvider),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => ErrorView(
          onRetry: () => ref.invalidate(taskMasterControllerProvider),
        ),
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
}
