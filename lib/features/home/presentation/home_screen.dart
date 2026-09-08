import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/error_view.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../daily_plan/application/daily_plan_logic.dart';
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
    final assignedMin = slots.fold(
      0,
      (s, slot) =>
          s +
          planData
              .assignmentsForSlot(slot.id)
              .fold<int>(0, (inner, item) => inner + item.durationMinutes),
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      // No bottom navigation here: the router shell owns it now, so it stays
      // put on every top-level screen instead of only on this one.
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
                    assignedMinutes: assignedMin,
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
    final assignedMin = slots.fold(
      0,
      (s, slot) =>
          s +
          planData
              .assignmentsForSlot(slot.id)
              .fold<int>(0, (inner, item) => inner + item.durationMinutes),
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Row(
          children: [
            // ── Sidebar ──────────────────────────────────────
            _Sidebar(today: today),

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
                            assignedMinutes: assignedMin,
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
/// The brand column beside the wide home: identity, the category legend and
/// the week card.
///
/// It used to carry its own five nav buttons. Navigation now belongs to the
/// router shell's [ShellNavigationRail], which every branch gets — two lists
/// of the same destinations, one of them only ever right on this screen, was
/// the bug (C-1).
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.today});
  final DateTime today;

  @override
  Widget build(BuildContext context) {
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
                  // Tall enough for the highest bar (30) plus its day label:
                  // 40 clipped the row by 7 px wherever the wide layout was
                  // actually rendered.
                  height: 48,
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

// ── Hero card ─────────────────────────────────────────────────
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.date,
    required this.freeMinutes,
    required this.assignedMinutes,
    required this.hasPlan,
  });
  final DateTime date;
  final int freeMinutes;
  final int assignedMinutes;
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
              // The headline is the day's whole free time; what the user acts
              // on is what is left of it once the plan is taken out (M-12).
              if (hasPlan) ...[
                const SizedBox(height: 10),
                Text(
                  '残り ${formatHoursMinutes(remainingFreeMinutes(freeMinutes: freeMinutes, assignedMinutes: assignedMinutes))}'
                  '（割り当て済み ${formatHoursMinutes(assignedMinutes)}）',
                  style: TextStyle(fontSize: 11, color: AppColors.onDeepMt),
                ),
              ],
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
                    '今日の計画がまだありません。日次計画から作成しましょう。',
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
      label: 'タスク一覧を開く',
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
/// The app's persistent bottom navigation, drawn by the router shell on every
/// top-level screen rather than by the home screen alone.
///
/// [currentIndex] indexes [shellBranchPaths], so the highlighted tab is always
/// the branch the shell is actually showing — it used to hard-code 今日 as
/// active, which said "home" on the tasks screen.
///
/// The bar adds the system navigation inset below its 70 px content so the
/// icons and labels stay above the gesture bar on edge-to-edge devices
/// (Android 15+); without it the lower half of the row is hidden.
class HomeBottomNav extends StatelessWidget {
  const HomeBottomNav({super.key, required this.currentIndex, this.onSelect});

  /// Index into [shellBranchPaths] of the destination being shown.
  final int currentIndex;

  /// How a tap changes destination. Left null (in tests, or anywhere outside
  /// the shell) the bar falls back to a plain `context.go`.
  final ValueChanged<int>? onSelect;

  static const double contentHeight = 70;

  void _select(BuildContext context, int index) {
    final select = onSelect;
    if (select != null) {
      select(index);
      return;
    }
    context.go(shellBranchPaths[index]);
  }

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
            active: currentIndex == 0,
            onTap: () => _select(context, 0),
          ),
          _NavBtn(
            icon: Icons.checklist_rounded,
            label: 'タスク',
            active: currentIndex == 1,
            onTap: () => _select(context, 1),
          ),
          // Centre button — the daily plan, the one screen the whole app is for.
          Expanded(
            child: Center(
              child: Semantics(
                selected: currentIndex == 2,
                button: true,
                label: '日次計画',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _select(context, 2),
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
                          border: currentIndex == 2
                              ? Border.all(color: AppColors.clayInk, width: 2)
                              : null,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.clay.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Icon(
                          currentIndex == 2
                              ? Icons.calendar_today_rounded
                              : Icons.add,
                          color: Colors.white,
                          size: 22,
                        ),
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
            active: currentIndex == 3,
            onTap: () => _select(context, 3),
          ),
          _NavBtn(
            icon: Icons.category_outlined,
            label: '設定',
            active: currentIndex == 4,
            onTap: () => _select(context, 4),
          ),
        ],
      ),
    );
  }
}

/// The wide-layout twin of [HomeBottomNav]: the same five destinations, in the
/// same order, down the left edge.
///
/// Built by the router shell, so every top-level screen has it — the sidebar
/// [_WideHome] used to draw was home's alone, which left the other four
/// branches with no navigation at all above 800 dp (C-1).
class ShellNavigationRail extends StatelessWidget {
  const ShellNavigationRail({
    super.key,
    required this.currentIndex,
    this.onSelect,
  });

  /// Index into [shellBranchPaths] of the destination being shown.
  final int currentIndex;

  /// How a tap changes destination; a plain `context.go` outside the shell.
  final ValueChanged<int>? onSelect;

  static const List<({IconData icon, String label})> destinations =
      <({IconData icon, String label})>[
        (icon: Icons.home_outlined, label: '今日'),
        (icon: Icons.checklist_rounded, label: 'タスク'),
        (icon: Icons.calendar_today_rounded, label: '日次計画'),
        (icon: Icons.bar_chart_rounded, label: '週次'),
        (icon: Icons.category_outlined, label: '設定'),
      ];

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      backgroundColor: AppColors.cream,
      selectedIndex: currentIndex,
      labelType: NavigationRailLabelType.all,
      indicatorColor: AppColors.claySoft,
      selectedIconTheme: const IconThemeData(color: AppColors.clay, size: 22),
      unselectedIconTheme: const IconThemeData(color: AppColors.ink3, size: 22),
      selectedLabelTextStyle: const TextStyle(
        fontSize: 11,
        color: AppColors.clay,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
      unselectedLabelTextStyle: const TextStyle(
        fontSize: 11,
        color: AppColors.ink3,
        letterSpacing: 0.4,
      ),
      onDestinationSelected: (index) {
        final select = onSelect;
        if (select != null) {
          select(index);
          return;
        }
        context.go(shellBranchPaths[index]);
      },
      destinations: <NavigationRailDestination>[
        for (final destination in destinations)
          NavigationRailDestination(
            icon: Icon(destination.icon),
            label: Text(destination.label),
          ),
      ],
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
