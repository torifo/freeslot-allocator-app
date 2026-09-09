import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/confirm_dialog.dart';
import '../../../core/error_view.dart';
import '../../../services/sync/conflict_record.dart';
import '../../../services/sync/conflict_resolver.dart';
import '../application/conflict_controller.dart';

/// 「設定 › PC と同期 › 競合」— every version a merge had to drop, and the way
/// to put one back.
class ConflictListScreen extends ConsumerWidget {
  const ConflictListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(conflictControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('競合')),
      body: records.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorView(
          message: '競合を読み込めませんでした（$error）',
          onRetry: () => ref.invalidate(conflictControllerProvider),
        ),
        data: (all) => _Body(all: all),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.all});

  final List<ConflictRecord> all;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hubMode = ref.watch(hubModeProvider) != null;
    final webId = ref.watch(webIdProvider);
    final open = openConflicts(all);
    final resolved = resolvedConflicts(all);
    // Role labels, not labels derived from a made-up device id: the batch
    // buttons apply to every open record at once, so there is no one device id
    // to read them from.
    final hubLabel = conflictPcLabel(hubMode: hubMode);
    final deviceLabel = conflictPhoneLabel();

    if (open.isEmpty && resolved.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('競合はありません'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text('未解決 ${open.length} 件', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          '同じ項目を PC とこの端末の両方で直したときの記録です。'
          '同期そのものは完了していて、いまは新しい方が入っています。',
          style: TextStyle(fontSize: 12),
        ),
        if (open.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton(
                onPressed: () => _resolveAll(context, ref, ConflictAdoption.hub, hubLabel),
                child: Text('すべて$hubLabelを採用'),
              ),
              OutlinedButton(
                onPressed: () => _resolveAll(context, ref, ConflictAdoption.device, deviceLabel),
                child: Text('すべて$deviceLabelを採用'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final record in open)
            _ConflictTile(record: record, hubMode: hubMode, webId: webId),
        ],
        if (resolved.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Card(
            child: ExpansionTile(
              title: Text('解決済み ${resolved.length} 件'),
              children: <Widget>[
                for (final record in resolved)
                  _ConflictTile(record: record, hubMode: hubMode, webId: webId),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _resolveAll(
    BuildContext context,
    WidgetRef ref,
    ConflictAdoption adopt,
    String label,
  ) async {
    final confirmed = await confirmAction(
      context,
      title: '$labelをすべて採用',
      message: '未解決の競合をすべて$labelにします。'
          'いま入っている方は上書きされ、次の同期で PC にも反映されます。',
      confirmLabel: '採用する',
    );
    if (!confirmed || !context.mounted) return;
    await _guard(
      context,
      () => ref.read(conflictControllerProvider.notifier).resolveAll(adopt),
    );
  }
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({required this.record, required this.hubMode, this.webId});

  final ConflictRecord record;
  final bool hubMode;
  final String? webId;

  @override
  Widget build(BuildContext context) {
    final winner = conflictWinnerLabel(record, hubMode: hubMode, webId: webId);
    final detected = DateTime.tryParse(record.detectedAt);
    final when = detected == null
        ? record.detectedAt
        : DateFormat('M/d HH:mm').format(detected.toLocal());
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(conflictLabel(record)),
      subtitle: Text(
        record.isOpen
            ? '$when 検出・いまは$winner'
            : '$when 検出・'
                  '${conflictResolutionLabel(record, hubMode: hubMode, webId: webId)}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/sync/conflicts/${record.id}'),
    );
  }
}

/// Runs a resolution and puts any refusal on screen instead of letting it
/// vanish into an unhandled async error.
///
/// Returns true only when the resolution actually went through. A caller that
/// navigates on success — the detail screen does — has to be able to tell a
/// refusal apart from a success, or it leaves the screen while the SnackBar it
/// just raised explains why nothing happened.
Future<bool> _guard(BuildContext context, Future<void> Function() body) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await body();
    return true;
  } on ConflictResolutionException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
    return false;
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('解決できませんでした（$error）')));
    return false;
  }
}

/// Shared with the detail screen, which needs the same guard.
Future<bool> runConflictAction(BuildContext context, Future<void> Function() body) =>
    _guard(context, body);
