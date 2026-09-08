import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme.dart';
import '../../../core/confirm_dialog.dart';
import '../../../core/error_view.dart';
import '../../../core/id_generator.dart';

import '../../task_master/application/task_master_controller.dart';
import '../../task_master/domain/task_models.dart';
import '../application/daily_plan_controller.dart';
import '../application/daily_plan_logic.dart';
import '../domain/daily_plan_models.dart';

class DailyPlanScreen extends ConsumerStatefulWidget {
  const DailyPlanScreen({super.key});

  @override
  ConsumerState<DailyPlanScreen> createState() => _DailyPlanScreenState();
}

class _DailyPlanScreenState extends ConsumerState<DailyPlanScreen> {
  static const _timelineViewModeKey = 'daily_plan_timeline_view_mode_v1';

  late DateTime _selectedDate;
  String? _draggingAssignmentId;
  _TimelineViewMode _timelineViewMode = _TimelineViewMode.noonToNoon;

  @override
  void initState() {
    super.initState();
    _selectedDate = dateOnly(DateTime.now());
    _loadTimelineViewMode();
  }

  @override
  Widget build(BuildContext context) {
    final dailyPlanState = ref.watch(dailyPlanControllerProvider);
    final taskMasterState = ref.watch(taskMasterControllerProvider);
    final currentDailyPlan = dailyPlanState.maybeWhen(
      data: (value) => value.planForDate(_selectedDate),
      orElse: () => null,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('日次計画'),
        actions: [
          IconButton(
            onPressed: () => _createPlanForAnotherDate(),
            icon: const Icon(Icons.post_add_outlined),
            tooltip: '別日を作成',
          ),
          IconButton(
            onPressed: () => _duplicateFromAnotherDate(),
            icon: const Icon(Icons.content_copy_outlined),
            tooltip: '別日に複製',
          ),
          IconButton(
            onPressed: () => _pickDate(context),
            icon: const Icon(Icons.event_outlined),
            tooltip: '日付を変更',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (currentDailyPlan == null) {
            _createPlanForSelectedDate();
          } else {
            _openSlotDialog(plan: currentDailyPlan);
          }
        },
        icon: Icon(
          currentDailyPlan == null
              ? Icons.calendar_month_outlined
              : Icons.add_alarm_outlined,
        ),
        label: Text(currentDailyPlan == null ? '当日計画を準備' : '自由時間枠を追加'),
      ),
      body: dailyPlanState.when(
        data: (dailyPlanData) => taskMasterState.when(
          data: (taskMasterData) {
            final plan = dailyPlanData.planForDate(_selectedDate);
            final slots = plan == null
                ? const <FreeTimeSlot>[]
                : dailyPlanData.slotsForPlan(plan.id);

            return ListView(
              // Bottom room for the extended FAB so the last slot stays
              // reachable.
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 88),
              children: [
                _DateSummaryCard(
                  date: _selectedDate,
                  plan: plan,
                  slotCount: slots.length,
                  assignedMinutes: slots.fold<int>(
                    0,
                    (sum, slot) =>
                        sum +
                        dailyPlanData
                            .assignmentsForSlot(slot.id)
                            .fold<int>(
                              0,
                              (inner, item) => inner + item.durationMinutes,
                            ),
                  ),
                  primaryActionLabel: plan == null ? '当日計画を作成' : '自由時間枠を追加',
                  onPrimaryAction: () {
                    if (plan == null) {
                      _createPlanForSelectedDate();
                    } else {
                      _openSlotDialog(plan: plan);
                    }
                  },
                  onCreateAnotherPlan: () {
                    _createPlanForAnotherDate();
                  },
                  onDuplicatePlan: () {
                    _duplicateFromAnotherDate();
                  },
                ),
                const SizedBox(height: 16),
                if (plan == null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'この日の DailyPlan はまだありません。',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '先に当日計画を準備し、その後モーダルから自由時間の開始・終了を選択して追加します。',
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: _createPlanForSelectedDate,
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: const Text('当日計画を準備'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                _DailyTimelineSection(
                  date: _selectedDate,
                  slots: slots,
                  assignmentsForSlot: (slotId) =>
                      dailyPlanData.assignmentsForSlot(slotId),
                  draggingAssignmentId: _draggingAssignmentId,
                  onEditSlot: (slot) =>
                      _openSlotDialog(plan: plan, existing: slot),
                  onDeleteSlot: _confirmDeleteSlot,
                  onAddAssignment: (slot) => _openAssignmentDialog(
                    slot: slot,
                    taskMasterData: taskMasterData,
                  ),
                  onEditAssignment: (slot, assignment) => _openAssignmentDialog(
                    slot: slot,
                    taskMasterData: taskMasterData,
                    existing: assignment,
                  ),
                  onMoveAssignment: (slot, assignment, {beforeAssignmentId}) =>
                      _moveAssignment(
                        assignment.id,
                        slot.id,
                        beforeAssignmentId: beforeAssignmentId,
                      ),
                  onDeleteAssignment: (assignment) =>
                      _deleteAssignment(assignment.id),
                  onDragStateChanged: (assignmentId) {
                    setState(() => _draggingAssignmentId = assignmentId);
                  },
                  timelineViewMode: _timelineViewMode,
                  onTimelineViewModeChanged: _updateTimelineViewMode,
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => ErrorView(
            onRetry: () => ref.invalidate(taskMasterControllerProvider),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => ErrorView(
          onRetry: () => ref.invalidate(dailyPlanControllerProvider),
        ),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final result = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() => _selectedDate = dateOnly(result));
  }

  Future<void> _createPlanForSelectedDate() async {
    await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .ensurePlanForDate(_selectedDate);
    });
  }

  Future<void> _createPlanForAnotherDate() async {
    final result = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
      helpText: '作成先の日付を選択',
    );
    if (result == null) {
      return;
    }
    final selectedDate = dateOnly(result);
    final succeeded = await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .ensurePlanForDate(selectedDate);
    });
    if (!succeeded || !mounted) {
      return;
    }
    setState(() => _selectedDate = selectedDate);
  }

  Future<void> _duplicateFromAnotherDate() async {
    final sourceDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate.subtract(const Duration(days: 1)),
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
      helpText: '複製元の日付を選択',
    );
    if (sourceDate == null) {
      return;
    }

    final normalizedSource = dateOnly(sourceDate);
    final currentState = ref
        .read(dailyPlanControllerProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    if (currentState == null) {
      return;
    }
    final sourcePlan = currentState.planForDate(normalizedSource);
    if (sourcePlan == null) {
      _showMessage('複製元の DailyPlan が見つかりません。');
      return;
    }
    final sourceSlots = currentState.slotsForPlan(sourcePlan.id);
    if (sourceSlots.isEmpty) {
      _showMessage('複製元の DailyPlan に自由時間枠がありません。');
      return;
    }
    final sourceAssignmentsBySlot = <String, List<SlotTaskAssignment>>{
      for (final slot in sourceSlots)
        slot.id: currentState.assignmentsForSlot(slot.id),
    };
    if (!mounted) {
      return;
    }

    final options = await showDialog<_DuplicatePlanOptions>(
      context: context,
      builder: (context) => _DuplicatePlanDialog(
        sourceDate: normalizedSource,
        targetDate: _selectedDate,
        sourceSlots: sourceSlots,
        sourceAssignmentsBySlot: sourceAssignmentsBySlot,
        targetExists: currentState.planForDate(_selectedDate) != null,
      ),
    );
    if (options == null) {
      return;
    }

    await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .duplicatePlan(
            sourceDate: normalizedSource,
            targetDate: _selectedDate,
            sourceSlotIds: options.slotIds,
            sourceAssignmentIds: options.assignmentIds,
            includeAssignments: options.includeAssignments,
            replaceExisting: options.mergeMode == _DuplicateMergeMode.replace,
          );
    });
  }

  Future<void> _openSlotDialog({
    DailyPlan? plan,
    FreeTimeSlot? existing,
  }) async {
    final needsPlan = existing == null && plan == null;
    final resolvedPlan = existing == null
        ? (plan ??
              await ref
                  .read(dailyPlanControllerProvider.notifier)
                  .ensurePlanForDate(_selectedDate))
        : plan;
    if (needsPlan && !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _SlotEditDialog(
        planDate: existing?.startAt ?? resolvedPlan!.date,
        planId: existing?.dailyPlanId ?? resolvedPlan!.id,
        initialSlot: existing,
        onSave: (slot) async {
          return _runWithErrorHandling(() async {
            await ref
                .read(dailyPlanControllerProvider.notifier)
                .upsertSlot(slot);
          });
        },
      ),
    );
  }

  Future<void> _openAssignmentDialog({
    required FreeTimeSlot slot,
    required TaskMasterStateData taskMasterData,
    SlotTaskAssignment? existing,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _AssignmentEditDialog(
        slot: slot,
        taskMasterData: taskMasterData,
        initialAssignment: existing,
        onSave: (assignment) async {
          return _runWithErrorHandling(() async {
            await ref
                .read(dailyPlanControllerProvider.notifier)
                .upsertAssignment(assignment);
          });
        },
      ),
    );
  }

  Future<void> _confirmDeleteSlot(FreeTimeSlot slot) async {
    final assignmentCount = ref
        .read(dailyPlanControllerProvider)
        .value
        ?.assignmentsForSlot(slot.id)
        .length;
    final confirmed = await confirmDelete(
      context,
      name: slot.label.isEmpty ? '自由時間枠' : slot.label,
      description: (assignmentCount ?? 0) > 0
          ? 'この枠に登録した$assignmentCount件の予定もあわせて削除されます。'
          : 'この枠に登録した予定もあわせて削除されます。',
    );
    if (!confirmed) {
      return;
    }
    await _deleteSlot(slot.id);
  }

  Future<void> _deleteSlot(String slotId) async {
    await _runWithErrorHandling(() async {
      await ref.read(dailyPlanControllerProvider.notifier).deleteSlot(slotId);
    });
  }

  Future<void> _deleteAssignment(String assignmentId) async {
    await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .deleteAssignment(assignmentId);
    });
  }

  Future<void> _moveAssignment(
    String assignmentId,
    String targetSlotId, {
    String? beforeAssignmentId,
  }) async {
    await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .moveAssignmentToSlot(
            assignmentId: assignmentId,
            targetSlotId: targetSlotId,
            beforeAssignmentId: beforeAssignmentId,
          );
    });
  }

  Future<void> _loadTimelineViewMode() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_timelineViewModeKey);
    if (!mounted) {
      return;
    }
    setState(() {
      _timelineViewMode = _TimelineViewModeX.fromStorageKey(value);
    });
  }

  Future<void> _updateTimelineViewMode(_TimelineViewMode mode) async {
    setState(() => _timelineViewMode = mode);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_timelineViewModeKey, mode.storageKey);
  }

  Future<bool> _runWithErrorHandling(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on DailyPlanValidationException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage(saveFailureMessage);
    }
    return false;
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _TimelineViewMode { noonToNoon, midnightToMidnight }

extension _TimelineViewModeX on _TimelineViewMode {
  String get storageKey {
    switch (this) {
      case _TimelineViewMode.noonToNoon:
        return 'noon_to_noon';
      case _TimelineViewMode.midnightToMidnight:
        return 'midnight_to_midnight';
    }
  }

  String get label {
    switch (this) {
      case _TimelineViewMode.noonToNoon:
        return '12:00-翌12:00';
      case _TimelineViewMode.midnightToMidnight:
        return '00:00-24:00';
    }
  }

  static _TimelineViewMode fromStorageKey(String? value) {
    return _TimelineViewMode.values.firstWhere(
      (mode) => mode.storageKey == value,
      orElse: () => _TimelineViewMode.noonToNoon,
    );
  }
}

class _DateSummaryCard extends StatelessWidget {
  const _DateSummaryCard({
    required this.date,
    required this.plan,
    required this.slotCount,
    required this.assignedMinutes,
    required this.primaryActionLabel,
    required this.onPrimaryAction,
    required this.onCreateAnotherPlan,
    required this.onDuplicatePlan,
  });

  final DateTime date;
  final DailyPlan? plan;
  final int slotCount;
  final int assignedMinutes;
  final String primaryActionLabel;
  final VoidCallback onPrimaryAction;
  final VoidCallback onCreateAnotherPlan;
  final VoidCallback onDuplicatePlan;

  @override
  Widget build(BuildContext context) {
    final hasConfiguredSlots = plan != null && slotCount > 0;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.deep,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.deep.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: -40,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.clay.withValues(alpha: 0.4),
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
                        'DAILY PLAN',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.4,
                          color: AppColors.onDeepMt,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        DateFormat('M月d日 (E)', 'ja').format(date),
                        style: japaneseSerifTextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: AppColors.onDeep,
                          letterSpacing: 0.4,
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
                      color: hasConfiguredSlots
                          ? AppColors.clay
                          : AppColors.onDeepMt.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      hasConfiguredSlots ? '作成済み' : '未作成',
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
              Row(
                children: [
                  _HeroPill(label: '自由時間枠', value: '$slotCount 件'),
                  const SizedBox(width: 10),
                  _HeroPill(label: '割り当て', value: '$assignedMinutes 分'),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _HeroButton(
                    label: primaryActionLabel,
                    primary: true,
                    onTap: onPrimaryAction,
                  ),
                  _HeroButton(label: '別日を作成', onTap: onCreateAnotherPlan),
                  _HeroButton(label: '別日に複製', onTap: onDuplicatePlan),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 9,
              letterSpacing: 0.6,
              color: AppColors.onDeepMt,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: japaneseSerifTextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppColors.onDeep,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroButton extends StatelessWidget {
  const _HeroButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: primary
                    ? AppColors.clay
                    : Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                label,
                style: japaneseSerifTextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DailyTimelineSection extends StatefulWidget {
  const _DailyTimelineSection({
    required this.date,
    required this.slots,
    required this.assignmentsForSlot,
    required this.draggingAssignmentId,
    required this.onEditSlot,
    required this.onDeleteSlot,
    required this.onAddAssignment,
    required this.onEditAssignment,
    required this.onMoveAssignment,
    required this.onDeleteAssignment,
    required this.onDragStateChanged,
    required this.timelineViewMode,
    required this.onTimelineViewModeChanged,
  });

  final DateTime date;
  final List<FreeTimeSlot> slots;
  final List<SlotTaskAssignment> Function(String slotId) assignmentsForSlot;
  final String? draggingAssignmentId;
  final ValueChanged<FreeTimeSlot> onEditSlot;
  final ValueChanged<FreeTimeSlot> onDeleteSlot;
  final ValueChanged<FreeTimeSlot> onAddAssignment;
  final void Function(FreeTimeSlot slot, SlotTaskAssignment assignment)
  onEditAssignment;
  final void Function(
    FreeTimeSlot slot,
    SlotTaskAssignment assignment, {
    String? beforeAssignmentId,
  })
  onMoveAssignment;
  final ValueChanged<SlotTaskAssignment> onDeleteAssignment;
  final ValueChanged<String?> onDragStateChanged;
  final _TimelineViewMode timelineViewMode;
  final ValueChanged<_TimelineViewMode> onTimelineViewModeChanged;

  @override
  State<_DailyTimelineSection> createState() => _DailyTimelineSectionState();
}

class _DailyTimelineSectionState extends State<_DailyTimelineSection> {
  static const double _hourHeight = 72;
  static const double _gutterWidth = 56;

  /// Vertical breathing room above and below the grid so the first and last
  /// hour labels can sit centred on their lines instead of being pushed
  /// inside the rounded corner of the grid card.
  static const double _timelinePadding = 12;

  @override
  Widget build(BuildContext context) {
    final window = resolveTimelineWindow(
      defaultStart: _defaultTimelineStart(widget.date),
      defaultEnd: _defaultTimelineEnd(widget.date),
      slots: widget.slots,
      assignments: widget.slots.expand(
        (slot) => widget.assignmentsForSlot(slot.id),
      ),
    );
    final timelineStart = window.start;
    final timelineEnd = window.end;
    final totalMinutes = timelineEnd.difference(timelineStart).inMinutes;
    final timelineHeight = (totalMinutes / 60) * _hourHeight;
    final canvasHeight = timelineHeight + _timelinePadding * 2;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('自由時間タイムライン', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Googleカレンダーのように時間軸で自由時間枠を確認できます。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<_TimelineViewMode>(
              segments: _TimelineViewMode.values
                  .map(
                    (mode) => ButtonSegment<_TimelineViewMode>(
                      value: mode,
                      label: Text(mode.label),
                    ),
                  )
                  .toList(),
              selected: <_TimelineViewMode>{widget.timelineViewMode},
              onSelectionChanged: (selection) {
                widget.onTimelineViewModeChanged(selection.first);
              },
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth = constraints.maxWidth;
                final timelineWidth = (availableWidth - _gutterWidth - 8).clamp(
                  280.0,
                  704.0,
                );
                final contentWidth = timelineWidth + _gutterWidth + 8;

                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: contentWidth,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: _gutterWidth,
                          height: canvasHeight,
                          child: _TimelineGutter(
                            start: timelineStart,
                            end: timelineEnd,
                            hourHeight: _hourHeight,
                            topPadding: _timelinePadding,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: timelineWidth,
                          height: canvasHeight,
                          child: Stack(
                            children: [
                              Positioned(
                                top: _timelinePadding,
                                bottom: _timelinePadding,
                                left: 0,
                                right: 0,
                                child: _TimelineGrid(
                                  start: timelineStart,
                                  end: timelineEnd,
                                  hourHeight: _hourHeight,
                                ),
                              ),
                              ...widget.slots.map((slot) {
                                final top =
                                    _timelinePadding +
                                    _offsetForTime(
                                      slot.startAt,
                                      timelineStart,
                                      _hourHeight,
                                    );
                                final height =
                                    (slot.durationMinutes / 60) * _hourHeight;
                                return Positioned(
                                  top: top,
                                  left: 0,
                                  right: 0,
                                  height: height.clamp(48, double.infinity),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: _TimelineSlotBlock(
                                      slot: slot,
                                      assignmentCount: widget
                                          .assignmentsForSlot(slot.id)
                                          .length,
                                      onTap: () => widget.onEditSlot(slot),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              'タイムラインは自由時間の見え方を確認するための表示です。自由時間枠の登録は上部のボタンからモーダルで行います。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (widget.slots.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('自由時間枠の詳細', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ...widget.slots.map(
                (slot) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SlotCard(
                    slot: slot,
                    assignments: widget.assignmentsForSlot(slot.id),
                    draggingAssignmentId: widget.draggingAssignmentId,
                    onEditSlot: () => widget.onEditSlot(slot),
                    onDeleteSlot: () => widget.onDeleteSlot(slot),
                    onAddAssignment: () => widget.onAddAssignment(slot),
                    onEditAssignment: (assignment) =>
                        widget.onEditAssignment(slot, assignment),
                    onMoveAssignment: (assignment, {beforeAssignmentId}) =>
                        widget.onMoveAssignment(
                          slot,
                          assignment,
                          beforeAssignmentId: beforeAssignmentId,
                        ),
                    onDeleteAssignment: widget.onDeleteAssignment,
                    onDragStateChanged: widget.onDragStateChanged,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  DateTime _defaultTimelineStart(DateTime selectedDate) {
    switch (widget.timelineViewMode) {
      case _TimelineViewMode.noonToNoon:
        return DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
          12,
        );
      case _TimelineViewMode.midnightToMidnight:
        return DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
        );
    }
  }

  DateTime _defaultTimelineEnd(DateTime selectedDate) {
    switch (widget.timelineViewMode) {
      case _TimelineViewMode.noonToNoon:
        return DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day + 1,
          12,
        );
      case _TimelineViewMode.midnightToMidnight:
        return DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day + 1,
        );
    }
  }

  double _offsetForTime(DateTime value, DateTime start, double hourHeight) {
    return value.difference(start).inMinutes / 60 * hourHeight;
  }
}

class _TimelineGutter extends StatelessWidget {
  const _TimelineGutter({
    required this.start,
    required this.end,
    required this.hourHeight,
    this.topPadding = 0,
  });

  final DateTime start;
  final DateTime end;
  final double hourHeight;
  final double topPadding;

  /// Half the rendered height of a `labelSmall` line, used to centre each
  /// label on its hour line.
  static const double _labelHalfHeight = 8;

  @override
  Widget build(BuildContext context) {
    final hours = <DateTime>[];
    var cursor = start;
    while (!cursor.isAfter(end)) {
      hours.add(cursor);
      cursor = cursor.add(const Duration(hours: 1));
    }

    return Stack(
      children: [
        for (var index = 0; index < hours.length; index += 1)
          Positioned(
            top: topPadding + index * hourHeight - _labelHalfHeight,
            left: 0,
            right: 0,
            child: Text(
              DateFormat('HH:mm').format(hours[index]),
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
      ],
    );
  }

}

class _TimelineGrid extends StatelessWidget {
  const _TimelineGrid({
    required this.start,
    required this.end,
    required this.hourHeight,
  });

  final DateTime start;
  final DateTime end;
  final double hourHeight;

  @override
  Widget build(BuildContext context) {
    final lines = <DateTime>[];
    var cursor = start;
    while (!cursor.isAfter(end)) {
      lines.add(cursor);
      cursor = cursor.add(const Duration(hours: 1));
    }

    // The first and last hours coincide with the card border, so drawing
    // them again would leave a straight line poking out of the rounded
    // corners. Interior lines are clipped to the same radius for safety.
    final interior = lines.length > 2
        ? lines.sublist(1, lines.length - 1)
        : const <DateTime>[];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            ...interior.map((hour) {
              final top = hour.difference(start).inMinutes / 60 * hourHeight;
              return Positioned(
                top: top,
                left: 0,
                right: 0,
                child: Container(height: 1, color: AppColors.line),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _TimelineSlotBlock extends StatelessWidget {
  const _TimelineSlotBlock({
    required this.slot,
    required this.assignmentCount,
    required this.onTap,
  });

  final FreeTimeSlot slot;
  final int assignmentCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cream,
      borderRadius: BorderRadius.circular(12),
      shadowColor: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: const Border(
              left: BorderSide(color: AppColors.clay, width: 3),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        slot.label.isEmpty ? '自由時間枠' : slot.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: japaneseSerifTextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${slot.durationMinutes}分',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.ink3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${DateFormat('HH:mm').format(slot.startAt)} – ${DateFormat('HH:mm').format(slot.endAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.ink2),
                ),
                const SizedBox(height: 3),
                Text(
                  '予定 $assignmentCount 件',
                  style: const TextStyle(fontSize: 10, color: AppColors.ink3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.slot,
    required this.assignments,
    required this.draggingAssignmentId,
    required this.onEditSlot,
    required this.onDeleteSlot,
    required this.onAddAssignment,
    required this.onEditAssignment,
    required this.onMoveAssignment,
    required this.onDeleteAssignment,
    required this.onDragStateChanged,
  });

  final FreeTimeSlot slot;
  final List<SlotTaskAssignment> assignments;
  final String? draggingAssignmentId;
  final VoidCallback onEditSlot;
  final VoidCallback onDeleteSlot;
  final VoidCallback onAddAssignment;
  final ValueChanged<SlotTaskAssignment> onEditAssignment;
  final void Function(
    SlotTaskAssignment assignment, {
    String? beforeAssignmentId,
  })
  onMoveAssignment;
  final ValueChanged<SlotTaskAssignment> onDeleteAssignment;
  final ValueChanged<String?> onDragStateChanged;

  @override
  Widget build(BuildContext context) {
    final rangeLabel =
        '${DateFormat('MM/dd HH:mm').format(slot.startAt)} - ${DateFormat('MM/dd HH:mm').format(slot.endAt)}';
    final assignedMinutes = assignments.fold<int>(
      0,
      (sum, item) => sum + item.durationMinutes,
    );
    final isDragging = draggingAssignmentId != null;
    final containsDraggedAssignment = assignments.any(
      (item) => item.id == draggingAssignmentId,
    );
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slot.label.isEmpty ? '自由時間枠' : slot.label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text('$rangeLabel / ${slot.durationMinutes}分'),
                      const SizedBox(height: 4),
                      Text('割り当て済み $assignedMinutes分'),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      onEditSlot();
                    } else if (value == 'delete') {
                      onDeleteSlot();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('枠を編集')),
                    PopupMenuItem(value: 'delete', child: Text('枠を削除')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onAddAssignment,
              icon: const Icon(Icons.playlist_add_outlined),
              label: const Text('この枠に予定を追加'),
            ),
            const SizedBox(height: 12),
            if (assignments.isEmpty) ...[
              const Text('まだ予定は入っていません。'),
              const SizedBox(height: 8),
              _AssignmentDropZone(
                onAccept: (assignment) => onMoveAssignment(assignment),
                label: 'ここにドロップして先頭から配置',
                isDragging: isDragging,
              ),
            ] else ...[
              const Text('長押しでドラッグすると、各予定の手前か末尾に再配置できます。'),
              if (containsDraggedAssignment) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '移動中: ドロップ先を選ぶと、この枠の予定順を組み替えます。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              ...assignments.indexed.expand((entry) {
                final (index, assignment) = entry;
                return <Widget>[
                  _AssignmentDropZone(
                    onAccept: (dragged) => onMoveAssignment(
                      dragged,
                      beforeAssignmentId: assignment.id,
                    ),
                    label:
                        '${DateFormat('HH:mm').format(assignment.startAt)} の前に挿入',
                    isDragging: isDragging,
                    noOpAssignmentIds: <String>{
                      assignment.id,
                      if (index > 0) assignments[index - 1].id,
                    },
                  ),
                  LongPressDraggable<SlotTaskAssignment>(
                    data: assignment,
                    onDragStarted: () => onDragStateChanged(assignment.id),
                    onDragCompleted: () => onDragStateChanged(null),
                    onDraggableCanceled: (velocity, offset) =>
                        onDragStateChanged(null),
                    onDragEnd: (_) => onDragStateChanged(null),
                    feedback: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: colorScheme.primary,
                              width: 2,
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: colorScheme.shadow.withValues(
                                  alpha: 0.2,
                                ),
                                blurRadius: 16,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: _AssignmentTile(
                            assignment: assignment,
                            onEdit: null,
                            onDelete: null,
                            dense: true,
                          ),
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.35,
                      child: _AssignmentTile(
                        assignment: assignment,
                        onEdit: () => onEditAssignment(assignment),
                        onDelete: () => onDeleteAssignment(assignment),
                      ),
                    ),
                    child: _AssignmentTile(
                      assignment: assignment,
                      onEdit: () => onEditAssignment(assignment),
                      onDelete: () => onDeleteAssignment(assignment),
                      highlighted: draggingAssignmentId == assignment.id,
                    ),
                  ),
                ];
              }),
              _AssignmentDropZone(
                onAccept: (assignment) => onMoveAssignment(assignment),
                label: '末尾に移動',
                isDragging: isDragging,
                noOpAssignmentIds: <String>{assignments.last.id},
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AssignmentDropZone extends StatelessWidget {
  const _AssignmentDropZone({
    required this.onAccept,
    required this.label,
    required this.isDragging,
    this.noOpAssignmentIds = const <String>{},
  });

  final ValueChanged<SlotTaskAssignment> onAccept;
  final String label;
  final bool isDragging;

  /// Assignments whose drop here would not change the order.
  final Set<String> noOpAssignmentIds;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DragTarget<SlotTaskAssignment>(
      onWillAcceptWithDetails: (details) =>
          !noOpAssignmentIds.contains(details.data.id),
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: isActive ? 14 : 10,
          ),
          decoration: BoxDecoration(
            color: isActive
                ? colorScheme.secondaryContainer
                : (isDragging
                      ? colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.45,
                        )
                      : null),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? colorScheme.secondary
                  : (isDragging
                        ? colorScheme.primary.withValues(alpha: 0.55)
                        : colorScheme.outlineVariant),
              width: isActive ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isActive ? Icons.arrow_downward_rounded : Icons.swap_vert,
                size: 18,
                color: isActive
                    ? colorScheme.onSecondaryContainer
                    : (isDragging ? colorScheme.primary : null),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isActive ? '$label にドロップ' : label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: isActive || isDragging
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: isActive
                        ? colorScheme.onSecondaryContainer
                        : (isDragging ? colorScheme.primary : null),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _DuplicateMergeMode { append, replace }

class _DuplicatePlanOptions {
  const _DuplicatePlanOptions({
    required this.slotIds,
    required this.assignmentIds,
    required this.includeAssignments,
    required this.mergeMode,
  });

  final List<String> slotIds;
  final List<String> assignmentIds;
  final bool includeAssignments;
  final _DuplicateMergeMode mergeMode;
}

class _DuplicatePlanDialog extends StatefulWidget {
  const _DuplicatePlanDialog({
    required this.sourceDate,
    required this.targetDate,
    required this.sourceSlots,
    required this.sourceAssignmentsBySlot,
    required this.targetExists,
  });

  final DateTime sourceDate;
  final DateTime targetDate;
  final List<FreeTimeSlot> sourceSlots;
  final Map<String, List<SlotTaskAssignment>> sourceAssignmentsBySlot;
  final bool targetExists;

  @override
  State<_DuplicatePlanDialog> createState() => _DuplicatePlanDialogState();
}

class _DuplicatePlanDialogState extends State<_DuplicatePlanDialog> {
  late final Set<String> _selectedSlotIds;
  late final Set<String> _selectedAssignmentIds;
  var _includeAssignments = true;
  var _mergeMode = _DuplicateMergeMode.append;

  @override
  void initState() {
    super.initState();
    _selectedSlotIds = widget.sourceSlots.map((slot) => slot.id).toSet();
    _selectedAssignmentIds = widget.sourceAssignmentsBySlot.values
        .expand((items) => items)
        .map((item) => item.id)
        .toSet();
    _mergeMode = widget.targetExists
        ? _DuplicateMergeMode.append
        : _DuplicateMergeMode.replace;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('部分複製を設定'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${DateFormat('yyyy/MM/dd').format(widget.sourceDate)} から ${DateFormat('yyyy/MM/dd').format(widget.targetDate)} へ複製します。',
          ),
          const SizedBox(height: 12),
          const Text('複製する自由時間枠'),
          const SizedBox(height: 8),
          ...widget.sourceSlots.map((slot) {
            final range =
                '${DateFormat('MM/dd HH:mm').format(slot.startAt)} - ${DateFormat('MM/dd HH:mm').format(slot.endAt)}';
            final slotAssignments =
                widget.sourceAssignmentsBySlot[slot.id] ??
                const <SlotTaskAssignment>[];
            return CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _selectedSlotIds.contains(slot.id),
              title: Text(slot.label.isEmpty ? '自由時間枠' : slot.label),
              subtitle: Text(range),
              onChanged: (value) {
                setState(() {
                  if (value ?? false) {
                    _selectedSlotIds.add(slot.id);
                    _selectedAssignmentIds.addAll(
                      slotAssignments.map((item) => item.id),
                    );
                  } else {
                    _selectedSlotIds.remove(slot.id);
                    _selectedAssignmentIds.removeAll(
                      slotAssignments.map((item) => item.id),
                    );
                  }
                });
              },
            );
          }),
          if (_selectedSlotIds.isNotEmpty && _includeAssignments) ...[
            const SizedBox(height: 8),
            const Text('複製する予定'),
            const SizedBox(height: 8),
            ...widget.sourceSlots.expand((slot) {
              final slotAssignments =
                  widget.sourceAssignmentsBySlot[slot.id] ??
                  const <SlotTaskAssignment>[];
              if (!_selectedSlotIds.contains(slot.id) ||
                  slotAssignments.isEmpty) {
                return const <Widget>[];
              }
              return <Widget>[
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 4),
                  child: Text(
                    slot.label.isEmpty ? '自由時間枠' : slot.label,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                ...slotAssignments.map((assignment) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _selectedAssignmentIds.contains(assignment.id),
                      title: Text(assignment.taskTitle),
                      subtitle: Text(
                        '${DateFormat('HH:mm').format(assignment.startAt)} - ${DateFormat('HH:mm').format(assignment.endAt)}',
                      ),
                      onChanged: (value) {
                        setState(() {
                          if (value ?? false) {
                            _selectedAssignmentIds.add(assignment.id);
                          } else {
                            _selectedAssignmentIds.remove(assignment.id);
                          }
                        });
                      },
                    ),
                  );
                }),
              ];
            }),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('予定も含めて複製'),
            value: _includeAssignments,
            onChanged: (value) => setState(() => _includeAssignments = value),
          ),
          if (widget.targetExists) ...[
            const SizedBox(height: 8),
            const Text('複製先に既存計画があります'),
            const SizedBox(height: 8),
            SegmentedButton<_DuplicateMergeMode>(
              segments: const <ButtonSegment<_DuplicateMergeMode>>[
                ButtonSegment<_DuplicateMergeMode>(
                  value: _DuplicateMergeMode.append,
                  label: Text('追加する'),
                ),
                ButtonSegment<_DuplicateMergeMode>(
                  value: _DuplicateMergeMode.replace,
                  label: Text('置き換える'),
                ),
              ],
              selected: <_DuplicateMergeMode>{_mergeMode},
              onSelectionChanged: (value) {
                setState(() => _mergeMode = value.first);
              },
            ),
            const SizedBox(height: 8),
            Text(
              _mergeMode == _DuplicateMergeMode.append
                  ? '既存の自由時間枠を残しつつ、選択分だけ追加します。'
                  : '既存の自由時間枠と予定を削除して複製内容で置換します。',
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _selectedSlotIds.isEmpty
              ? null
              : () {
                  Navigator.of(context).pop(
                    _DuplicatePlanOptions(
                      slotIds: _selectedSlotIds.toList(),
                      assignmentIds: _selectedAssignmentIds.toList(),
                      includeAssignments: _includeAssignments,
                      mergeMode: _mergeMode,
                    ),
                  );
                },
          child: const Text('複製'),
        ),
      ],
    );
  }
}

class _AssignmentTile extends StatelessWidget {
  const _AssignmentTile({
    required this.assignment,
    required this.onEdit,
    required this.onDelete,
    this.dense = false,
    this.highlighted = false,
  });

  final SlotTaskAssignment assignment;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool dense;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.primaryContainer.withValues(alpha: 0.55)
            : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        dense: dense,
        contentPadding: EdgeInsets.zero,
        title: Text(assignment.taskTitle),
        subtitle: Text(
          [
            '${DateFormat('HH:mm').format(assignment.startAt)} - ${DateFormat('HH:mm').format(assignment.endAt)}',
            assignment.taskKind.label,
            assignment.categoryName ?? '未分類',
            '${assignment.durationMinutes}分',
            if (assignment.memo.isNotEmpty) assignment.memo,
          ].join(' / '),
        ),
        trailing: onEdit == null && onDelete == null
            ? null
            : PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    onEdit?.call();
                  } else if (value == 'delete') {
                    onDelete?.call();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('予定を編集')),
                  PopupMenuItem(value: 'delete', child: Text('予定を削除')),
                ],
              ),
      ),
    );
  }
}

class _SlotEditDialog extends StatefulWidget {
  const _SlotEditDialog({
    required this.planDate,
    required this.planId,
    required this.onSave,
    this.initialSlot,
  });

  final DateTime planDate;
  final String planId;
  final FreeTimeSlot? initialSlot;
  final Future<bool> Function(FreeTimeSlot slot) onSave;

  @override
  State<_SlotEditDialog> createState() => _SlotEditDialogState();
}

class _SlotEditDialogState extends State<_SlotEditDialog> {
  late final TextEditingController _labelController;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late bool _endNextDay;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSlot;
    _labelController = TextEditingController(text: initial?.label ?? '');
    final initialStart = initial?.startAt ?? widget.planDate;
    _startTime = TimeOfDay.fromDateTime(initialStart);
    final defaultEnd =
        initial?.endAt ?? initialStart.add(const Duration(hours: 1));
    _endTime = TimeOfDay.fromDateTime(defaultEnd);
    _endNextDay = !dateOnly(
      defaultEnd,
    ).isAtSameMomentAs(dateOnly(initialStart));
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startAt = _combine(widget.planDate, _startTime);
    final endAt = _combine(
      widget.planDate.add(Duration(days: _endNextDay ? 1 : 0)),
      _endTime,
    );
    return AlertDialog(
      scrollable: true,
      title: Text(widget.initialSlot == null ? '自由時間枠を追加' : '自由時間枠を編集'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _labelController,
            decoration: const InputDecoration(labelText: 'ラベル'),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '開始と終了はモーダル内で分単位に選択できます。\n'
              '${DateFormat('MM/dd HH:mm').format(startAt)} - ${DateFormat('MM/dd HH:mm').format(endAt)}'
              ' / ${endAt.difference(startAt).inMinutes}分',
            ),
          ),
          const SizedBox(height: 12),
          _TimelinePickerRow(
            label: '開始',
            value: _startTime,
            suffix: '当日',
            onTap: () async {
              final picked = await showModalBottomSheet<TimeOfDay>(
                context: context,
                isScrollControlled: true,
                builder: (context) => _PreciseTimePickerSheet(
                  title: '開始時間を選択',
                  initialValue: _startTime,
                ),
              );
              if (picked != null) {
                setState(() => _startTime = picked);
              }
            },
          ),
          const SizedBox(height: 12),
          _TimelinePickerRow(
            label: '終了',
            value: _endTime,
            suffix: _endNextDay ? '翌日' : '当日',
            onTap: () async {
              final picked = await showModalBottomSheet<TimeOfDay>(
                context: context,
                isScrollControlled: true,
                builder: (context) => _PreciseTimePickerSheet(
                  title: '終了時間を選択',
                  initialValue: _endTime,
                ),
              );
              if (picked != null) {
                setState(() => _endTime = picked);
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('終了は翌日'),
            value: _endNextDay,
            onChanged: (value) => setState(() => _endNextDay = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _isSaving
              ? null
              : () async {
                  setState(() => _isSaving = true);
                  try {
                    final saved = await widget.onSave(
                      FreeTimeSlot(
                        id: widget.initialSlot?.id ?? generateId('slot'),
                        dailyPlanId:
                            widget.initialSlot?.dailyPlanId ?? widget.planId,
                        startAt: startAt,
                        endAt: endAt,
                        label: _labelController.text.trim(),
                      ),
                    );
                    if (saved && context.mounted) {
                      Navigator.of(context).pop();
                    }
                  } finally {
                    if (mounted) {
                      setState(() => _isSaving = false);
                    }
                  }
                },
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }

  DateTime _combine(DateTime date, TimeOfDay time) {
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}

class _TimelinePickerRow extends StatelessWidget {
  const _TimelinePickerRow({
    required this.label,
    required this.value,
    required this.suffix,
    required this.onTap,
  });

  final String label;
  final TimeOfDay value;
  final String suffix;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value.format(context)),
            const SizedBox(width: 8),
            Text(suffix, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 8),
            const Icon(Icons.expand_more),
          ],
        ),
      ),
    );
  }
}

class _PreciseTimePickerSheet extends StatefulWidget {
  const _PreciseTimePickerSheet({
    required this.title,
    required this.initialValue,
  });

  final String title;
  final TimeOfDay initialValue;

  @override
  State<_PreciseTimePickerSheet> createState() =>
      _PreciseTimePickerSheetState();
}

class _PreciseTimePickerSheetState extends State<_PreciseTimePickerSheet> {
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialValue.hour;
    _minute = widget.initialValue.minute;
  }

  @override
  Widget build(BuildContext context) {
    final selected = TimeOfDay(hour: _hour, minute: _minute);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  selected.format(context),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  height: 240,
                  child: Row(
                    children: [
                      Expanded(
                        child: _NumberPickerColumn(
                          label: '時',
                          value: _hour,
                          values: List<int>.generate(24, (index) => index),
                          onSelected: (value) => setState(() => _hour = value),
                          formatLabel: (value) =>
                              value.toString().padLeft(2, '0'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _NumberPickerColumn(
                          label: '分',
                          value: _minute,
                          values: List<int>.generate(60, (index) => index),
                          onSelected: (value) =>
                              setState(() => _minute = value),
                          formatLabel: (value) =>
                              value.toString().padLeft(2, '0'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('キャンセル'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(selected),
                    child: const Text('選択'),
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

class _NumberPickerColumn extends StatelessWidget {
  const _NumberPickerColumn({
    required this.label,
    required this.value,
    required this.values,
    required this.onSelected,
    required this.formatLabel,
  });

  final String label;
  final int value;
  final List<int> values;
  final ValueChanged<int> onSelected;
  final String Function(int value) formatLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: ListView.builder(
              itemCount: values.length,
              itemBuilder: (context, index) {
                final item = values[index];
                final isSelected = item == value;
                return Material(
                  color: isSelected
                      ? Theme.of(
                          context,
                        ).colorScheme.secondaryContainer.withValues(alpha: 0.9)
                      : Colors.transparent,
                  child: InkWell(
                    onTap: () => onSelected(item),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Text(
                        formatLabel(item),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _AssignmentEditDialog extends StatefulWidget {
  const _AssignmentEditDialog({
    required this.slot,
    required this.taskMasterData,
    required this.onSave,
    this.initialAssignment,
  });

  final FreeTimeSlot slot;
  final TaskMasterStateData taskMasterData;
  final SlotTaskAssignment? initialAssignment;
  final Future<bool> Function(SlotTaskAssignment assignment) onSave;

  @override
  State<_AssignmentEditDialog> createState() => _AssignmentEditDialogState();
}

class _AssignmentEditDialogState extends State<_AssignmentEditDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _memoController;
  late String _taskId;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late bool _startNextDay;
  late bool _endNextDay;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAssignment;
    final defaultStart = initial?.startAt ?? widget.slot.startAt;
    final tentativeEnd = widget.slot.startAt.add(const Duration(minutes: 30));
    final defaultEnd =
        initial?.endAt ??
        (tentativeEnd.isAfter(widget.slot.endAt)
            ? widget.slot.endAt
            : tentativeEnd);
    final firstTaskId =
        initial?.taskId ?? widget.taskMasterData.tasks.firstOrNull?.id ?? '';

    _titleController = TextEditingController(
      text:
          initial?.taskTitle ??
          widget.taskMasterData.tasks
              .where((task) => task.id == firstTaskId)
              .firstOrNull
              ?.title ??
          '',
    );
    _memoController = TextEditingController(text: initial?.memo ?? '');
    _taskId = firstTaskId;
    _startTime = TimeOfDay.fromDateTime(defaultStart);
    _endTime = TimeOfDay.fromDateTime(defaultEnd);
    _startNextDay = !_isSameDay(defaultStart, widget.slot.startAt);
    _endNextDay = !_isSameDay(defaultEnd, widget.slot.startAt);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.taskMasterData.tasks;
    final selectedTask = tasks.where((task) => task.id == _taskId).firstOrNull;

    return AlertDialog(
      scrollable: true,
      title: Text(widget.initialAssignment == null ? '予定を追加' : '予定を編集'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('TaskMaster にタスクがありません。先にタスクを作成してください。'),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _taskId.isEmpty ? null : _taskId,
              decoration: const InputDecoration(labelText: '元タスク'),
              items: tasks
                  .map(
                    (task) => DropdownMenuItem<String>(
                      value: task.id,
                      child: Text(task.title),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                final task = tasks
                    .where((item) => item.id == value)
                    .firstOrNull;
                setState(() {
                  _taskId = value;
                  if (task != null) {
                    _titleController.text = task.title;
                  }
                });
              },
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: '当日の表示名'),
          ),
          const SizedBox(height: 12),
          _TimeRow(
            label: '開始',
            value: _startTime,
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: _startTime,
              );
              if (picked != null) {
                setState(() => _startTime = picked);
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('開始は翌日'),
            value: _startNextDay,
            onChanged: (value) => setState(() => _startNextDay = value),
          ),
          _TimeRow(
            label: '終了',
            value: _endTime,
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: _endTime,
              );
              if (picked != null) {
                setState(() => _endTime = picked);
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('終了は翌日'),
            value: _endNextDay,
            onChanged: (value) => setState(() => _endNextDay = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _memoController,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'メモ'),
          ),
          if (selectedTask != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'カテゴリ: ${_categoryName(selectedTask) ?? '未分類'} / 見積もり ${selectedTask.estimatedMinutes}分',
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: tasks.isEmpty || _isSaving
              ? null
              : () async {
                  final task = tasks
                      .where((item) => item.id == _taskId)
                      .firstOrNull;
                  if (task == null) {
                    return;
                  }

                  final startAt = _combine(
                    widget.slot.startAt.add(
                      Duration(days: _startNextDay ? 1 : 0),
                    ),
                    _startTime,
                  );
                  final endAt = _combine(
                    widget.slot.startAt.add(
                      Duration(days: _endNextDay ? 1 : 0),
                    ),
                    _endTime,
                  );
                  setState(() => _isSaving = true);
                  final bool saved;
                  try {
                    saved = await widget.onSave(
                      SlotTaskAssignment(
                        id:
                            widget.initialAssignment?.id ??
                            generateId('assignment'),
                        dailyPlanId: widget.slot.dailyPlanId,
                        slotId: widget.slot.id,
                        taskId: task.id,
                        taskTitle: _titleController.text.trim().isEmpty
                            ? task.title
                            : _titleController.text.trim(),
                        taskKind: task.kind,
                        startAt: startAt,
                        endAt: endAt,
                        sortOrder: widget.initialAssignment?.sortOrder ?? 0,
                        categoryId: task.categoryId,
                        categoryName: _categoryName(task),
                        memo: _memoController.text.trim(),
                      ),
                    );
                  } finally {
                    if (mounted) {
                      setState(() => _isSaving = false);
                    }
                  }
                  if (saved && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }

  String? _categoryName(TaskMaster task) {
    if (task.categoryId == null) {
      return null;
    }
    final categories = widget.taskMasterData.categoriesFor(task.kind);
    return categories
        .where((category) => category.id == task.categoryId)
        .firstOrNull
        ?.name;
  }

  DateTime _combine(DateTime date, TimeOfDay time) {
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  bool _isSameDay(DateTime left, DateTime right) {
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final TimeOfDay value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(
          children: [
            Expanded(child: Text(value.format(context))),
            const Icon(Icons.schedule_outlined),
          ],
        ),
      ),
    );
  }
}
