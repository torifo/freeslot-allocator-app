import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../task_master/application/task_master_controller.dart';
import '../../task_master/domain/task_models.dart';

class WeeklyReportScreen extends ConsumerWidget {
  const WeeklyReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(taskMasterControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('週次レポート')),
      body: state.when(
        data: (data) {
          final totalMinutes = data.tasks.fold<int>(
            0,
            (sum, task) => sum + task.estimatedMinutes,
          );

          final mustDoMinutes = data.tasks
              .where((task) => task.kind == TaskKind.mustDo)
              .fold<int>(0, (sum, task) => sum + task.estimatedMinutes);
          final wantToDoMinutes = totalMinutes - mustDoMinutes;

          final categoryTotals = <String, int>{};
          for (final task in data.tasks) {
            final label = _categoryLabel(data, task) ?? '未分類';
            categoryTotals.update(
              label,
              (value) => value + task.estimatedMinutes,
              ifAbsent: () => task.estimatedMinutes,
            );
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: ListTile(
                  title: const Text('合計見積もり時間'),
                  subtitle: const Text('TaskMaster登録タスクの合計'),
                  trailing: Text('$totalMinutes分'),
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
    );
  }

  String? _categoryLabel(TaskMasterStateData data, TaskMaster task) {
    if (task.categoryId == null) {
      return null;
    }
    final categories = data.categoriesFor(task.kind);
    return categories
        .where((category) => category.id == task.categoryId)
        .firstOrNull
        ?.name;
  }
}
