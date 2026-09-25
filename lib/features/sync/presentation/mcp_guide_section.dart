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
            const Text(
              'この Mac では、Claude Code から FRELOCATOR のタスクや計画を直接編集できます。手順:',
            ),
            const SizedBox(height: 12),
            const _Step(
              no: '1',
              title: 'リポジトリで HUB をビルドする',
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
              'アプリと HUB は同じファイルをロック付きで共有します。1 世代前は data.json.bak に残ります。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('ペアリングと QR のページ', style: theme.textTheme.labelLarge),
            const Text(
              'HUB が動いている間だけ、スマホとの LAN 同期を受け付けます。'
              'ペアリング用と QR 送信用のページの URL は sync_status の lan.pairingPage / lan.qrPage に出ます。'
              'URL には HUB を起動するたびに変わる秘密の文字列が入るので、毎回 sync_status から取り直してください。'
              'どちらのページもこの Mac からしか開けません。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('ブラウザ版をこの Mac で開く', style: theme.textTheme.labelLarge),
            const Text(
              'HUB は FRELOCATOR のブラウザ版も配信できます。'
              'tools/hub で npm run build:web を一度実行してから、'
              'sync_status の lan.webApp.url をこの Mac のブラウザで開いてください。'
              'この URL にも HUB を起動するたびに変わる秘密の文字列が入ります。',
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

/// Web (public build) only: how to drive FRELOCATOR from Claude Code.
///
/// The public web build at app.frelocator.riumu.net talks to no hub, so this
/// card is the only place an engineer opening that URL can learn that a hub
/// exists. It deliberately prints no local path — there is no `dart:io` here,
/// and the reader's machine is not necessarily the one this page runs on.
class WebMcpGuideSection extends StatelessWidget {
  const WebMcpGuideSection({super.key});

  static const String repoUrl =
      'https://github.com/torifo/freeslot-allocator-app.git';

  /// One self-contained instruction block for a coding agent (Claude Code,
  /// Codex, etc.). Pasting it is the whole setup: the agent clones, builds,
  /// verifies the MCP server, and opens the hub-served web app.
  static const String agentPrompt =
      'FRELOCATOR の HUB（Claude Code 向け MCP サーバー）をこの PC にセットアップしてください。\n'
      '\n'
      '1. リポジトリを取得する: git clone $repoUrl '
      '（既にあれば git pull）\n'
      '2. HUB をビルドする: cd freeslot-allocator-app/tools/hub && '
      'npm install && npm run build && npm run build:web\n'
      '3. リポジトリ直下の .mcp.json に frelocator-hub'
      '（command: node, args: tools/hub/dist/index.js）が同梱されている。'
      'リポジトリのルートを作業ディレクトリとして開き直し、'
      'frelocator-hub の MCP ツールが使えることを sync_status を呼んで確認する。\n'
      '4. sync_status の結果の lan.webApp.url を、この PC の既定ブラウザで開く'
      '（macOS なら open <url>）。URL には HUB 起動ごとに変わる秘密の文字列が入るので、'
      '毎回 sync_status から取り直す。\n'
      '5. スマホと同期する場合は lan.pairingPage の URL を開いて QR を表示し、'
      'スマホの「PC と同期 > PC とペアリング」で読み取るよう案内する。'
      '競合があれば同期後にスマホの「競合」から採用側を選べる。\n'
      '\n'
      '完了したら、開いた URL と、データファイルの場所'
      '（macOS: ~/Library/Application Support/FRELOCATOR/data.json。'
      'アプリと HUB がロック付きで共有する）を報告してください。';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Claude Code（MCP）と連携する', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'エンジニア向け: PC 上で Claude Code から FRELOCATOR のタスクや計画を編集し、'
              'スマホに同期できます。'
              'このブラウザ版（公開 Web）は HUB と同期しません。'
              'HUB が配信するブラウザ版を使ってください。',
            ),
            const SizedBox(height: 12),
            const Text(
              '下のプロンプトをコーディングエージェント（Claude Code など）に貼り付けると、'
              '取得・ビルド・MCP の確認・ブラウザ版を開くところまで一度に進みます。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: SelectableText(
                  agentPrompt,
                  style: TextStyle(fontFamily: 'Menlo', fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('エージェント用プロンプトをコピー'),
                onPressed: () async {
                  await Clipboard.setData(
                    const ClipboardData(text: agentPrompt),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('コピーしました')));
                },
              ),
            ),
            const SizedBox(height: 12),
            Text('手動でやる場合', style: theme.textTheme.labelLarge),
            const Text(
              'リポジトリ（$repoUrl）を clone し、tools/hub で npm install と npm run build、'
              'npm run build:web を実行します。同梱の .mcp.json で frelocator-hub が登録されるので、'
              'Claude Code でリポジトリを開いて sync_status を実行し、'
              'lan.webApp.url をブラウザで開きます。'
              'スマホとは「PC と同期」のペアリングで LAN 同期します。',
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
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('コピーしました')));
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
