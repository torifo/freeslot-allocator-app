import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/storage/file_backed_store.dart';

/// macOS only: where the data lives and how to let Claude Code drive it.
///
/// The pairing and QR pages sit under a secret path that the hub regenerates
/// every time it starts, so this section deliberately does *not* print a URL —
/// it says to read the current one out of `sync_status` (see
/// `tools/hub/README.md`).
class McpGuideSection extends StatelessWidget {
  const McpGuideSection({super.key});

  static const String _mcpJson = '''{
  "mcpServers": {
    "frelocator-hub": {
      "command": "node",
      "args": ["tools/hub/dist/index.js"]
    }
  }
}''';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Claude Code（MCP）と連携', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('この Mac では、Claude Code から FRELOCATOR のタスクや計画を直接編集できます。手順:'),
            const SizedBox(height: 12),
            const _Step(
              no: '1',
              title: 'リポジトリでハブをビルドする',
              command: 'cd tools/hub && npm install && npm run build',
            ),
            const _Step(
              no: '2',
              title: 'リポジトリ直下の .mcp.json に登録する（同梱済み）',
              command: _mcpJson,
            ),
            const _Step(
              no: '3',
              title:
                  'Claude Code でリポジトリを開き直すと frelocator-hub が使えます。'
                  'sync_status ツールで状態を確認できます。',
            ),
            const SizedBox(height: 8),
            Text('データファイル', style: theme.textTheme.labelLarge),
            SelectableText(
              '${FileBackedStore.defaultDirectory()}/data.json',
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
            ),
            const Text(
              'アプリとハブは同じファイルをロック付きで共有します。1 世代前は data.json.bak に残ります。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('ペアリングと QR のページ', style: theme.textTheme.labelLarge),
            const Text(
              'ハブが動いている間だけ、スマホとの LAN 同期を受け付けます。'
              'ペアリング用と QR 送信用のページの URL は sync_status の lan.pairingPage / lan.qrPage に出ます。'
              'URL にはハブを起動するたびに変わる秘密の文字列が入るので、毎回 sync_status から取り直してください。'
              'どちらのページもこの Mac からしか開けません。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('ブラウザ版をこの Mac で開く', style: theme.textTheme.labelLarge),
            const Text(
              'ハブは FRELOCATOR のブラウザ版も配信できます。'
              'tools/hub で npm run build:web を一度実行してから、'
              'sync_status の lan.webApp.url をこの Mac のブラウザで開いてください。'
              'この URL にもハブを起動するたびに変わる秘密の文字列が入ります。',
              style: TextStyle(fontSize: 12),
            ),
            const Text(
              'ブラウザ版はこの Mac の data.json を直接読み書きします（ブラウザ側に控えは残りません）。'
              'lan.webApp.stale が true のときはビルドが古いので、npm run build:web をやり直してください。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.no, required this.title, this.command});

  final String no;
  final String title;
  final String? command;

  @override
  Widget build(BuildContext context) {
    final command = this.command;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('$no. $title'),
          if (command != null)
            Row(
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    command,
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: 'コピー',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('コピーしました')),
                    );
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
