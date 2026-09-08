import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme.dart';
import '../../../core/error_view.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../daily_plan/domain/daily_plan_models.dart';
import '../../task_master/application/task_master_controller.dart';
import '../../task_master/domain/task_models.dart';

// ── Root widget ───────────────────────────────────────────────
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taskState = ref.watch(taskMasterControllerProvider);
    final planState = ref.watch(dailyPlanControllerProvider);

    final isWide = MediaQuery.of(context).size.width >= 800;

    return taskState.when(
      data: (taskData) => planState.when(
        data: (planData) => isWide
            ? _WideHome(taskData: taskData, planData: planData)
            : _NarrowHome(taskData: taskData, planData: planData),
        loading: () => const _LoadingScaffold(),
        error: (e, _) => _ErrorScaffold(
          onRetry: () => ref.invalidate(dailyPlanControllerProvider),
        ),
      ),
      loading: () => const _LoadingScaffold(),
      error: (e, _) => _ErrorScaffold(
        onRetry: () => ref.invalidate(taskMasterControllerProvider),
      ),
    );
  }
}

// ── Mobile layout ─────────────────────────────────────────────
class _NarrowHome extends StatelessWidget {
  const _NarrowHome({required this.taskData, required this.planData});
  final TaskMasterStateData taskData;
  final DailyPlanStateData planData;

  @override
  Widget build(BuildContext context) {
    final today = _today();
    final plan = planData.planForDate(today);
    final slots = plan == null
        ? <FreeTimeSlot>[]
        : planData.slotsForPlan(plan.id);
    final freeMin = slots.fold(0, (s, slot) => s + slot.durationMinutes);

    return Scaffold(
      backgroundColor: AppColors.bg,
      bottomNavigationBar: const HomeBottomNav(),
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(date: today),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  _HeroCard(
                    date: today,
                    freeMinutes: freeMin,
                    hasPlan: plan != null,
                  ),
                  const SizedBox(height: 20),
                  _StatGrid(taskData: taskData, planData: planData),
                  const SizedBox(height: 20),
                  const _QuickActions(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── PC / wide layout ──────────────────────────────────────────
class _WideHome extends StatelessWidget {
  const _WideHome({required this.taskData, required this.planData});
  final TaskMasterStateData taskData;
  final DailyPlanStateData planData;

  @override
  Widget build(BuildContext context) {
    final today = _today();
    final plan = planData.planForDate(today);
    final slots = plan == null
        ? <FreeTimeSlot>[]
        : planData.slotsForPlan(plan.id);
    final freeMin = slots.fold(0, (s, slot) => s + slot.durationMinutes);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Row(
          children: [
            // ── Sidebar ──────────────────────────────────────
            _Sidebar(taskData: taskData, today: today),

            // ── Main content ─────────────────────────────────
            Expanded(
              child: Column(
                children: [
                  _WideHeader(date: today),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HeroCard(
                            date: today,
                            freeMinutes: freeMin,
                            hasPlan: plan != null,
                          ),
                          const SizedBox(height: 24),
                          _StatGrid(taskData: taskData, planData: planData),
                          const SizedBox(height: 24),
                          const _QuickActions(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Top bar (mobile) ──────────────────────────────────────────
class _TopBar extends StatelessWidget {
  const _TopBar({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.line2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FRELOCATOR · ${DateFormat('M月d日 E', 'ja').format(date)}',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.0,
                    color: AppColors.clay,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'おかえりなさい',
                  style: japaneseSerifTextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Wide header (PC) ──────────────────────────────────────────
class _WideHeader extends StatelessWidget {
  const _WideHeader({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 16),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.line2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${date.year} · ${DateFormat('MMMM', 'ja').format(date)} · ${DateFormat('E', 'ja').format(date)} · 第${_weekOfYear(date)}週',
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                  color: AppColors.clay,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${date.day}',
                    style: japaneseSerifTextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w500,
                      color: AppColors.ink,
                      height: 1,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    DateFormat('M月・EEE曜日', 'ja').format(date),
                    style: japaneseSerifTextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w500,
                      color: AppColors.ink2,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _weekOfYear(DateTime d) {
    final startOfYear = DateTime(d.year, 1, 1);
    return ((d.difference(startOfYear).inDays + startOfYear.weekday) / 7)
        .ceil();
  }
}

// ── Sidebar (PC) ──────────────────────────────────────────────
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.taskData, required this.today});
  final TaskMasterStateData taskData;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final items = [
      _NavItem(glyph: '○', label: '今日', route: '/', active: true),
      _NavItem(glyph: '▣', label: '日次計画', route: '/daily-plan'),
      _NavItem(
        glyph: '✓',
        label: 'TaskMaster',
        route: '/tasks',
        badge: '${taskData.tasks.length}',
      ),
      _NavItem(glyph: '▤', label: 'カテゴリ設定', route: '/categories'),
      _NavItem(glyph: '◐', label: '週次レポート', route: '/weekly-report'),
    ];

    return Container(
      width: 236,
      decoration: const BoxDecoration(
        color: AppColors.cream,
        border: Border(right: BorderSide(color: AppColors.line2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Frelocator',
                  style: japaneseSerifTextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w500,
                    color: AppColors.ink,
                    letterSpacing: 0.4,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  '余白の設計図',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.5,
                    color: AppColors.clay,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 28),
          ...items.map((item) => _SidebarNavButton(item: item)),
          const Divider(height: 28),
          const Padding(
            padding: EdgeInsets.only(left: 9, bottom: 8),
            child: Text(
              'CATEGORY',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.0,
                color: AppColors.ink3,
              ),
            ),
          ),
          ..._categoryLegend.map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: e.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    e.label,
                    style: japaneseSerifTextStyle(
                      fontSize: 12,
                      color: AppColors.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // Week mini card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.deep,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'THIS WEEK',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.0,
                    color: AppColors.clay,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '今週の計画を確認する',
                  style: japaneseSerifTextStyle(
                    fontSize: 12,
                    color: AppColors.onDeep,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 40,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(7, (i) {
                      // The mini week card is Monday-first, so index 0 is
                      // Monday and DateTime.monday == 1.
                      final isToday = i == today.weekday - 1;
                      final height = 10.0 + (i % 3) * 10;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                height: height,
                                decoration: BoxDecoration(
                                  color: isToday
                                      ? AppColors.clay
                                      : AppColors.ink2,
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(3),
                                    topRight: Radius.circular(3),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                ['月', '火', '水', '木', '金', '土', '日'][i],
                                style: TextStyle(
                                  fontSize: 9,
                                  color: isToday
                                      ? AppColors.clay
                                      : AppColors.ink3,
                                  fontWeight: isToday
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem({
    required this.glyph,
    required this.label,
    required this.route,
    this.active = false,
    this.badge,
  });
  final String glyph;
  final String label;
  final String route;
  final bool active;
  final String? badge;
}

class _SidebarNavButton extends StatelessWidget {
  const _SidebarNavButton({required this.item});
  final _NavItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: item.active ? AppColors.claySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => context.go(item.route),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  child: Text(
                    item.glyph,
                    style: TextStyle(
                      fontSize: 10,
                      color: item.active ? AppColors.clay : AppColors.ink3,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    item.label,
                    style: japaneseSerifTextStyle(
                      fontSize: 13,
                      fontWeight: item.active
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: item.active ? AppColors.clayInk : AppColors.ink2,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                if (item.badge != null)
                  Text(
                    item.badge!,
                    style: japaneseSerifTextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: item.active ? AppColors.clayInk : AppColors.ink3,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Hero card ─────────────────────────────────────────────────
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.date,
    required this.freeMinutes,
    required this.hasPlan,
  });
  final DateTime date;
  final int freeMinutes;
  final bool hasPlan;

  @override
  Widget build(BuildContext context) {
    final h = freeMinutes ~/ 60;
    final m = freeMinutes % 60;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.deep,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withValues(alpha: 0.32),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Radial glow
          Positioned(
            right: -40,
            top: -40,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.clay.withValues(alpha: 0.42),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.65],
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TODAY\'S FREE TIME',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.4,
                          color: AppColors.onDeepMt,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '今日の自由時間',
                        style: japaneseSerifTextStyle(
                          fontSize: 11,
                          color: AppColors.onDeepMt,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.clay,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      DateFormat('M月d日', 'ja').format(date),
                      style: japaneseSerifTextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Free time display
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$h',
                    style: japaneseSerifTextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.w500,
                      color: AppColors.onDeep,
                      height: 0.9,
                      letterSpacing: -1.5,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '時間',
                    style: japaneseSerifTextStyle(
                      fontSize: 18,
                      color: AppColors.onDeepMt,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '$m',
                    style: japaneseSerifTextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w500,
                      color: AppColors.onDeep,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '分',
                    style: japaneseSerifTextStyle(
                      fontSize: 14,
                      color: AppColors.onDeepMt,
                    ),
                  ),
                ],
              ),
              if (!hasPlan) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '今日の計画がまだありません。日次計画から準備しましょう。',
                    style: TextStyle(fontSize: 11, color: AppColors.onDeepMt),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ── Stat grid ─────────────────────────────────────────────────
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.taskData, required this.planData});
  final TaskMasterStateData taskData;
  final DailyPlanStateData planData;

  @override
  Widget build(BuildContext context) {
    final mustCount = taskData.tasks
        .where((t) => t.kind == TaskKind.mustDo)
        .length;
    final wantCount = taskData.tasks
        .where((t) => t.kind == TaskKind.wantToDo)
        .length;
    final planCount = planData.plans.length;
    final total = taskData.tasks.length;
    final items = [
      _StatTile(label: 'タスク総数', value: '$total', sub: '登録済み', deep: true),
      _StatTile(label: 'やるべきこと', value: '$mustCount', sub: '件'),
      _StatTile(label: 'やりたいこと', value: '$wantCount', sub: '件', warm: true),
      _StatTile(label: '日次計画', value: '$planCount', sub: '作成済み'),
    ];

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: items[0]),
            const SizedBox(width: 10),
            Expanded(child: items[1]),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: items[2]),
            const SizedBox(width: 10),
            Expanded(child: items[3]),
          ],
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.sub,
    this.deep = false,
    this.warm = false,
  });
  final String label;
  final String value;
  final String sub;
  final bool deep;
  final bool warm;

  @override
  Widget build(BuildContext context) {
    final bg = deep ? AppColors.deep : AppColors.cream;
    final fg = deep
        ? AppColors.onDeep
        : (warm ? AppColors.clay : AppColors.ink);
    final muted = deep ? AppColors.onDeepMt : AppColors.ink3;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: deep
            ? null
            : const Border.fromBorderSide(BorderSide(color: AppColors.line)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (deep)
            Positioned(
              right: -16,
              top: -16,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppColors.clay.withValues(alpha: 0.35),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.7],
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: muted,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                value,
                style: japaneseSerifTextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w500,
                  color: fg,
                  height: 1,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                sub,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.4,
                  color: muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Quick actions ─────────────────────────────────────────────
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  final _actions = const [
    _Action(
      glyph: '時',
      label: '日次計画を開く',
      sub: '自由時間枠の追加・編集',
      route: '/daily-plan',
    ),
    _Action(
      glyph: '任',
      label: 'TaskMaster を開く',
      sub: 'タスクを登録・編集する',
      route: '/tasks',
    ),
    _Action(
      glyph: '報',
      label: '週次レポートを見る',
      sub: '今週の振り返り',
      route: '/weekly-report',
    ),
    _Action(
      glyph: '設',
      label: 'カテゴリ設定を開く',
      sub: 'カテゴリを管理する',
      route: '/categories',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'クイックアクション',
          style: japaneseSerifTextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AppColors.cream,
            borderRadius: BorderRadius.circular(14),
            border: const Border.fromBorderSide(
              BorderSide(color: AppColors.line),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: _actions.indexed.map((e) {
              final (i, action) = e;
              return _ActionRow(
                action: action,
                showDivider: i < _actions.length - 1,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _Action {
  const _Action({
    required this.glyph,
    required this.label,
    required this.sub,
    required this.route,
  });
  final String glyph;
  final String label;
  final String sub;
  final String route;
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action, required this.showDivider});
  final _Action action;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: () => context.go(action.route),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.claySoft,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    action.glyph,
                    style: japaneseSerifTextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.clayInk,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.label,
                        style: japaneseSerifTextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.sub,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.ink3,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.ink3,
                ),
              ],
            ),
          ),
        ),
        if (showDivider) const Divider(height: 1, indent: 14, endIndent: 14),
      ],
    );
  }
}

// ── Bottom navigation (mobile) ────────────────────────────────
/// Bottom navigation of the home screen.
///
/// The bar adds the system navigation inset below its 70 px content so the
/// icons and labels stay above the gesture bar on edge-to-edge devices
/// (Android 15+); without it the lower half of the row is hidden.
class HomeBottomNav extends StatelessWidget {
  const HomeBottomNav({super.key});

  static const double contentHeight = 70;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      height: contentHeight * textScale + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.cream,
        border: Border(top: BorderSide(color: AppColors.line2)),
      ),
      child: Row(
        children: [
          _NavBtn(
            icon: Icons.home_outlined,
            label: '今日',
            active: true,
            onTap: () => context.go('/'),
          ),
          _NavBtn(
            icon: Icons.checklist_rounded,
            label: 'タスク',
            onTap: () => context.go('/tasks'),
          ),
          // Center FAB
          Expanded(
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.go('/daily-plan'),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppColors.clay,
                        borderRadius: BorderRadius.circular(13),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.clay.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.add,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          _NavBtn(
            icon: Icons.bar_chart_rounded,
            label: '週次',
            onTap: () => context.go('/weekly-report'),
          ),
          _NavBtn(
            icon: Icons.category_outlined,
            label: '設定',
            onTap: () => context.go('/categories'),
          ),
        ],
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  const _NavBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.clay : AppColors.ink3;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Utility widgets ───────────────────────────────────────────
class _LoadingScaffold extends StatelessWidget {
  const _LoadingScaffold();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: AppColors.bg,
    body: Center(child: CircularProgressIndicator(color: AppColors.clay)),
  );
}

class _ErrorScaffold extends StatelessWidget {
  const _ErrorScaffold({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.bg,
    body: ErrorView(onRetry: onRetry),
  );
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

// ── Category legend data ──────────────────────────────────────
class _CatEntry {
  const _CatEntry(this.label, this.color);
  final String label;
  final Color color;
}

const _categoryLegend = [
  _CatEntry('仕事', Color(0xFFA07B4E)),
  _CatEntry('家事', Color(0xFF5B6A85)),
  _CatEntry('雑務', Color(0xFF8B7053)),
  _CatEntry('趣味', Color(0xFFCA6E44)),
  _CatEntry('学習', Color(0xFF8E9A60)),
  _CatEntry('健康', Color(0xFFD18A6A)),
];
