import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _selectedDate = dateOnly(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final dailyPlanState = ref.watch(dailyPlanControllerProvider);
    final taskMasterState = ref.watch(taskMasterControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('日次計画'),
        actions: [
          IconButton(
            onPressed: () => _duplicateFromAnotherDate(),
            icon: const Icon(Icons.content_copy_outlined),
            tooltip: '別日を複製',
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
          _createPlanForSelectedDate();
        },
        icon: const Icon(Icons.calendar_month_outlined),
        label: const Text('当日計画を準備'),
      ),
      body: dailyPlanState.when(
        data: (dailyPlanData) => taskMasterState.when(
          data: (taskMasterData) {
            final plan = dailyPlanData.planForDate(_selectedDate);
            final slots = plan == null
                ? const <FreeTimeSlot>[]
                : dailyPlanData.slotsForPlan(plan.id);

            return ListView(
              padding: const EdgeInsets.all(20),
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
                  onCreatePlan: () {
                    _createPlanForSelectedDate();
                  },
                  onDuplicatePlan: () {
                    _duplicateFromAnotherDate();
                  },
                  onAddSlot: plan == null
                      ? null
                      : () => _openSlotDialog(plan: plan),
                ),
                const SizedBox(height: 16),
                if (plan == null)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'この日の DailyPlan はまだありません。先に「当日計画を準備」を押してから、自由時間枠を追加してください。',
                      ),
                    ),
                  )
                else if (slots.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '自由時間枠はまだありません。',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text('仕事後の 21:00-23:00 など、最初の枠を追加してください。'),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: () => _openSlotDialog(plan: plan),
                            icon: const Icon(Icons.add_alarm_outlined),
                            label: const Text('自由時間枠を追加'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ...slots.map(
                    (slot) => Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _SlotCard(
                        slot: slot,
                        assignments: dailyPlanData.assignmentsForSlot(slot.id),
                        onEditSlot: () =>
                            _openSlotDialog(plan: plan, existing: slot),
                        onDeleteSlot: () => _deleteSlot(slot.id),
                        onAddAssignment: () => _openAssignmentDialog(
                          slot: slot,
                          taskMasterData: taskMasterData,
                        ),
                        onEditAssignment: (assignment) => _openAssignmentDialog(
                          slot: slot,
                          taskMasterData: taskMasterData,
                          existing: assignment,
                        ),
                        onMoveAssignment: (assignment) =>
                            _moveAssignment(assignment.id, slot.id),
                        onDeleteAssignment: (assignment) =>
                            _deleteAssignment(assignment.id),
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

  Future<void> _pickDate(BuildContext context) async {
    final result = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
    );
    if (result == null) {
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
    final existingTarget = currentState?.planForDate(_selectedDate);
    var replaceExisting = false;
    if (existingTarget != null) {
      replaceExisting = await _confirmReplaceExistingPlan();
      if (!replaceExisting) {
        return;
      }
    }

    await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .duplicatePlan(
            sourceDate: normalizedSource,
            targetDate: _selectedDate,
            replaceExisting: replaceExisting,
          );
    });
  }

  Future<void> _openSlotDialog({
    required DailyPlan plan,
    FreeTimeSlot? existing,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _SlotEditDialog(
        planDate: plan.date,
        planId: plan.id,
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

  Future<void> _moveAssignment(String assignmentId, String targetSlotId) async {
    await _runWithErrorHandling(() async {
      await ref
          .read(dailyPlanControllerProvider.notifier)
          .moveAssignmentToSlot(
            assignmentId: assignmentId,
            targetSlotId: targetSlotId,
          );
    });
  }

  Future<bool> _runWithErrorHandling(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on DailyPlanValidationException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage(error.toString());
    }
    return false;
  }

  Future<bool> _confirmReplaceExistingPlan() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('既存の計画を置き換えますか'),
        content: const Text(
          '選択中の日付にはすでに DailyPlan があります。自由時間枠と予定を複製元の内容で置き換えます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('置き換える'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DateSummaryCard extends StatelessWidget {
  const _DateSummaryCard({
    required this.date,
    required this.plan,
    required this.slotCount,
    required this.assignedMinutes,
    required this.onCreatePlan,
    required this.onDuplicatePlan,
    required this.onAddSlot,
  });

  final DateTime date;
  final DailyPlan? plan;
  final int slotCount;
  final int assignedMinutes;
  final VoidCallback onCreatePlan;
  final VoidCallback onDuplicatePlan;
  final VoidCallback? onAddSlot;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DateFormat('yyyy/MM/dd (E)').format(date),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(plan == null ? '未作成の DailyPlan' : 'DailyPlan 作成済み'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('自由時間枠 $slotCount件')),
                Chip(label: Text('割り当て $assignedMinutes分')),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonal(
                  onPressed: onCreatePlan,
                  child: Text(plan == null ? '当日計画を作成' : '当日計画を再確認'),
                ),
                OutlinedButton.icon(
                  onPressed: onDuplicatePlan,
                  icon: const Icon(Icons.content_copy_outlined),
                  label: const Text('別日を複製'),
                ),
                if (onAddSlot != null)
                  OutlinedButton.icon(
                    onPressed: onAddSlot,
                    icon: const Icon(Icons.add_alarm_outlined),
                    label: const Text('自由時間枠を追加'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.slot,
    required this.assignments,
    required this.onEditSlot,
    required this.onDeleteSlot,
    required this.onAddAssignment,
    required this.onEditAssignment,
    required this.onMoveAssignment,
    required this.onDeleteAssignment,
  });

  final FreeTimeSlot slot;
  final List<SlotTaskAssignment> assignments;
  final VoidCallback onEditSlot;
  final VoidCallback onDeleteSlot;
  final VoidCallback onAddAssignment;
  final ValueChanged<SlotTaskAssignment> onEditAssignment;
  final ValueChanged<SlotTaskAssignment> onMoveAssignment;
  final ValueChanged<SlotTaskAssignment> onDeleteAssignment;

  @override
  Widget build(BuildContext context) {
    final rangeLabel =
        '${DateFormat('MM/dd HH:mm').format(slot.startAt)} - ${DateFormat('MM/dd HH:mm').format(slot.endAt)}';
    final assignedMinutes = assignments.fold<int>(
      0,
      (sum, item) => sum + item.durationMinutes,
    );

    return DragTarget<SlotTaskAssignment>(
      onWillAcceptWithDetails: (details) => details.data.slotId != slot.id,
      onAcceptWithDetails: (details) => onMoveAssignment(details.data),
      builder: (context, candidateData, rejectedData) => Card(
        color: candidateData.isEmpty
            ? null
            : Theme.of(context).colorScheme.secondaryContainer,
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
              if (assignments.isEmpty)
                const Text('まだ予定は入っていません。')
              else
                ...assignments.map(
                  (assignment) => LongPressDraggable<SlotTaskAssignment>(
                    data: assignment,
                    feedback: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: _AssignmentTile(
                          assignment: assignment,
                          onEdit: null,
                          onDelete: null,
                          dense: true,
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
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssignmentTile extends StatelessWidget {
  const _AssignmentTile({
    required this.assignment,
    required this.onEdit,
    required this.onDelete,
    this.dense = false,
  });

  final SlotTaskAssignment assignment;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return ListTile(
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

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSlot;
    _labelController = TextEditingController(text: initial?.label ?? '');
    _startTime = TimeOfDay.fromDateTime(initial?.startAt ?? widget.planDate);
    final defaultEnd =
        initial?.endAt ?? widget.planDate.add(const Duration(hours: 1));
    _endTime = TimeOfDay.fromDateTime(defaultEnd);
    _endNextDay = initial == null
        ? false
        : !dateOnly(initial.endAt).isAtSameMomentAs(dateOnly(initial.startAt));
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialSlot == null ? '自由時間枠を追加' : '自由時間枠を編集'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(labelText: 'ラベル'),
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
            const SizedBox(height: 12),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () async {
            final startAt = _combine(widget.planDate, _startTime);
            final endAt = _combine(
              widget.planDate.add(Duration(days: _endNextDay ? 1 : 0)),
              _endTime,
            );
            final saved = await widget.onSave(
              FreeTimeSlot(
                id:
                    widget.initialSlot?.id ??
                    'slot-${DateTime.now().microsecondsSinceEpoch}',
                dailyPlanId: widget.initialSlot?.dailyPlanId ?? widget.planId,
                startAt: startAt,
                endAt: endAt,
                label: _labelController.text.trim(),
              ),
            );
            if (saved && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  DateTime _combine(DateTime date, TimeOfDay time) {
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
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
      title: Text(widget.initialAssignment == null ? '予定を追加' : '予定を編集'),
      content: SingleChildScrollView(
        child: Column(
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: tasks.isEmpty
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
                  final saved = await widget.onSave(
                    SlotTaskAssignment(
                      id:
                          widget.initialAssignment?.id ??
                          'assignment-${DateTime.now().microsecondsSinceEpoch}',
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
                  if (saved && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          child: const Text('保存'),
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
