import 'package:flutter/material.dart';

import '../../../services/sync/sync_service.dart';

/// Asked when the hub refuses to merge (`purged_before`): one side has to win,
/// and the other side's unsynced work is thrown away.
///
/// The two destructive choices spell out *which* data disappears, because the
/// names alone ("PC の状態で置き換える") read as a direction, not as a loss.
class SyncReplaceDialog extends StatelessWidget {
  const SyncReplaceDialog({super.key, required this.message});

  /// The Japanese explanation from `syncErrorMessage('purged_before')`.
  final String message;

  static Future<SyncMode?> show(BuildContext context, String message) =>
      showDialog<SyncMode>(
        context: context,
        builder: (_) => SyncReplaceDialog(message: message),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('どちらを正にしますか？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message),
          const SizedBox(height: 12),
          Text(
            'PC の状態で置き換えると、この端末の未同期の変更は消えます。'
            'この端末で置き換えると、PC 側の変更（他の端末から届いた分も含む）が消えます。',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 12),
          const Text(
            '置き換える直前に、この端末のデータを 1 件だけ控えます。'
            '「直前の同期前に戻す」で 1 回だけ元に戻せます。',
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('やめる'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(SyncMode.takeHub),
          child: const Text('PC の状態で置き換える'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(SyncMode.takePhone),
          child: const Text('この端末で PC を置き換える'),
        ),
      ],
    );
  }
}
