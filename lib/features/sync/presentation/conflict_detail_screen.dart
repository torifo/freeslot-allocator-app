import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/error_view.dart';
import '../../../services/sync/conflict_record.dart';
import '../../../services/sync/conflict_resolver.dart';
import '../application/conflict_controller.dart';
import 'conflict_list_screen.dart' show runConflictAction;

/// One conflict, side by side, with the three ways out.
class ConflictDetailScreen extends ConsumerWidget {
  const ConflictDetailScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(conflictControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('競合の内容')),
      body: records.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorView(
          message: '競合を読み込めませんでした（$error）',
          onRetry: () => ref.invalidate(conflictControllerProvider),
        ),
        data: (all) {
          final record = all.where((c) => c.id == id).firstOrNull;
          if (record == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('この競合は見つかりませんでした。'),
              ),
            );
          }
          return _Body(record: record);
        },
      ),
    );
  }
}

/// Sync bookkeeping never belongs in the comparison the user reads; deletion is
/// drawn as its own 削除済み column instead of as a `deletedAt` row.
const Set<String> _skippedFields = <String>{
  'id', 'clock', 'updatedAt', 'migrated', 'deletedAt',
};

class _Body extends ConsumerWidget {
  const _Body({required this.record});

  final ConflictRecord record;

  ConflictSide get _hubSide => conflictPcSide(record);
  ConflictSide get _deviceSide => conflictPhoneSide(record);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hubMode = ref.watch(hubModeProvider) != null;
    final webId = ref.watch(webIdProvider);
    final names = conflictSideNames(record, hubMode: hubMode, webId: webId);
    final hubLabel = names.pc;
    final deviceLabel = names.phone;
    final detected = DateTime.tryParse(record.detectedAt);
    final hub = _hubSide.snapshot;
    final device = _deviceSide.snapshot;
    final fields = <String>{...hub.keys, ...device.keys}
        .where((f) => !_skippedFields.contains(f))
        .toList()
      ..sort();
    // Compared as JSON, not as the strings the table draws: `_display` maps
    // `null` and `false` onto text of their own, but it is a rendering rule and
    // a future addition to it must not be able to make two different values
    // look identical to the comparison.
    final differing = fields
        .where((f) => jsonEncode(hub[f]) != jsonEncode(device[f]))
        .toList();
    final same = fields.where((f) => !differing.contains(f)).toList();
    final oneSideDeleted = _hubSide.isDeleted || _deviceSide.isDeleted;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(conflictLabel(record), style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          detected == null
              ? '検出 ${record.detectedAt}'
              : '検出 ${DateFormat('yyyy/M/d HH:mm').format(detected.toLocal())}',
          style: theme.textTheme.bodySmall,
        ),
        if (!record.isOpen)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'この競合はすでに解決済みです'
              '（${conflictResolutionLabel(record, hubMode: hubMode, webId: webId)}）。',
              style: TextStyle(color: theme.colorScheme.primary),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: Text(hubLabel, style: theme.textTheme.labelLarge)),
            const SizedBox(width: 12),
            Expanded(child: Text(deviceLabel, style: theme.textTheme.labelLarge)),
          ],
        ),
        const Divider(),
        if (oneSideDeleted)
          // A tombstone carries no fields, so a field-by-field table would draw
          // one side as a column of blanks rather than as a deletion.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _SideSummary(side: _hubSide, fields: fields)),
              const SizedBox(width: 12),
              Expanded(child: _SideSummary(side: _deviceSide, fields: fields)),
            ],
          )
        else ...<Widget>[
          Text('違いのある項目', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          if (differing.isEmpty)
            const Text('内容の違いはありません（更新のタイミングだけが競合しました）。')
          else
            for (final field in differing)
              _FieldRow(
                field: field,
                hub: hub[field],
                device: device[field],
                highlighted: true,
              ),
          if (same.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Text('同じ項目', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final field in same)
              _FieldRow(
                field: field,
                hub: hub[field],
                device: device[field],
                highlighted: false,
              ),
          ],
        ],
        const SizedBox(height: 24),
        if (record.isOpen) ...<Widget>[
          const Text(
            '採用した方はこの端末の新しい編集として書き込まれ、次の同期で PC にも伝わります。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: () => _resolve(context, ref, ConflictAdoption.hub),
                child: Text('$hubLabelを採用'),
              ),
              FilledButton.tonal(
                onPressed: () => _resolve(context, ref, ConflictAdoption.device),
                child: Text('$deviceLabelを採用'),
              ),
              TextButton(
                onPressed: () => _resolve(context, ref, ConflictAdoption.current),
                child: const Text('現状のまま'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _resolve(BuildContext context, WidgetRef ref, ConflictAdoption adopt) async {
    final navigator = Navigator.of(context);
    final ok = await runConflictAction(
      context,
      () => ref.read(conflictControllerProvider.notifier).resolve(record.id, adopt),
    );
    // Only on success. A refusal — a purged entity, an unreadable snapshot —
    // leaves the record open, so leaving the screen would take the SnackBar
    // explaining it away with the screen and look like the choice was taken.
    if (!ok) return;
    // Back to the list, which is where the remaining records are. A detail
    // screen opened as the whole route (tests, deep links) has nothing to pop.
    if (navigator.canPop()) navigator.pop();
  }
}

class _SideSummary extends StatelessWidget {
  const _SideSummary({required this.side, required this.fields});

  final ConflictSide side;
  final List<String> fields;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (side.isDeleted) {
      return Text(
        '削除済み',
        style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final field in fields)
          if (side.snapshot.containsKey(field))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${conflictFieldLabel(field)}: ${_display(side.snapshot[field])}',
                style: theme.textTheme.bodySmall,
              ),
            ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.field,
    required this.hub,
    required this.device,
    required this.highlighted,
  });

  final String field;
  final Object? hub;
  final Object? device;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = highlighted
        ? theme.textTheme.bodyMedium
        : theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            conflictFieldLabel(field),
            style: theme.textTheme.labelSmall?.copyWith(
              color: highlighted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: Text(_display(hub), style: style)),
              const SizedBox(width: 12),
              Expanded(child: Text(_display(device), style: style)),
            ],
          ),
        ],
      ),
    );
  }
}

String _display(Object? value) => switch (value) {
  null => '（なし）',
  true => 'ON',
  false => 'OFF',
  _ => '$value',
};
