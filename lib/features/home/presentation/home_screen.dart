import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import '../../task_master/domain/task_models.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(taskMasterControllerProvider);
    final dailyPlanState = ref.watch(dailyPlanControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Frelocator')),
      body: state.when(
        data: (data) => dailyPlanState.when(
          data: (dailyPlanData) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const _HeroCard(),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _SummaryCard(
                    title: 'タスク総数',
                    value: '${data.tasks.length}',
                    caption: 'TaskMasterに登録済み',
                  ),
                  _SummaryCard(
                    title: 'やるべきこと',
                    value:
                        '${data.tasks.where((task) => task.kind == TaskKind.mustDo).length}',
                    caption: '優先対応が必要なもの',
                  ),
                  _SummaryCard(
                    title: 'やりたいこと',
                    value:
                        '${data.tasks.where((task) => task.kind == TaskKind.wantToDo).length}',
                    caption: '余白で進めたいもの',
                  ),
                  _SummaryCard(
                    title: '日次計画',
                    value: '${dailyPlanData.plans.length}',
                    caption: '作成済みDailyPlan',
                  ),
                  _SummaryCard(
                    title: 'カテゴリ共有',
                    value: data.shareCategories ? 'ON' : 'OFF',
                    caption: '設定画面から切替',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/tasks'),
                icon: const Icon(Icons.playlist_add_check_circle_outlined),
                label: const Text('TaskMasterを管理する'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/daily-plan'),
                icon: const Icon(Icons.calendar_today_outlined),
                label: const Text('日次計画を作成する'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/categories'),
                icon: const Icon(Icons.category_outlined),
                label: const Text('カテゴリ設定を開く'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/weekly-report'),
                icon: const Icon(Icons.pie_chart_outline),
                label: const Text('週次レポートを見る'),
              ),
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(child: Text(error.toString())),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text(error.toString())),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E847F), Color(0xFFC7683A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自由時間の棚卸しを、カテゴリ設計から始める。',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'TaskMaster とカテゴリ設定を先に固めておくと、日次計画と週次集計がぶれにくくなります。',
            style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.value,
    required this.caption,
  });

  final String title;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              const SizedBox(height: 10),
              Text(
                value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(caption),
            ],
          ),
        ),
      ),
    );
  }
}
