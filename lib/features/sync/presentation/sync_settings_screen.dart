import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/device_clock.dart';
import '../../../services/app_data_service.dart';
import '../../../services/sync/file_exporter.dart';
import '../../../services/sync/sync_progress.dart';
import '../../../services/sync/sync_service.dart';
import '../../../services/sync/sync_settings.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import '../application/sync_in_flight.dart';
import 'mcp_guide_section.dart';
import 'sync_progress_panel.dart';
import 'sync_replace_dialog.dart';

/// 「PC と同期」— the one screen that owns every hand-off with the hub: LAN
/// sync, pairing, QR receive, file export and (on macOS) file import.
class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  final SyncProgressController _progress = SyncProgressController();

  SyncSettings? _settings;
  bool _hasBackup = false;
  bool _running = false;

  bool get _isMac => !kIsWeb && Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final settings = await ref.read(syncSettingsStoreProvider).load();
    final hasBackup = await ref.read(syncServiceProvider).hasBackup;
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _hasBackup = hasBackup;
    });
  }

  /// Runs one sync-shaped operation behind the progress panel.
  ///
  /// The panel stays up until the user dismisses it, so a summary or an error
  /// is never flashed past them; only a `purged_before` answer closes it early,
  /// because that outcome is a question rather than a result.
  Future<void> _runWithPanel(Future<SyncOutcome> Function() run) async {
    if (_running) return;
    setState(() => _running = true);
    ref.read(syncInFlightProvider.notifier).update(running: true);
    final navigator = Navigator.of(context);
    final Future<void> panel = showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => SyncProgressPanel(
        controller: _progress,
        onCancel: _progress.cancel,
        onClose: () => Navigator.of(context).pop(),
      ),
    );

    final SyncOutcome outcome;
    try {
      outcome = await run();
    } finally {
      ref.read(syncInFlightProvider.notifier).update(running: false);
      if (mounted) setState(() => _running = false);
    }
    if (!mounted) return;

    if (outcome is SyncNeedsReplace) {
      navigator.pop();
      await panel;
      if (!mounted) return;
      await _askReplace(outcome.message);
      return;
    }
    if (outcome is SyncApplied) {
      ref.invalidate(taskMasterControllerProvider);
      ref.invalidate(dailyPlanControllerProvider);
    }
    await _reload();
    await panel;
  }

  Future<void> _askReplace(String message) async {
    final mode = await SyncReplaceDialog.show(context, message);
    if (mode == null || !mounted) return;
    await _runWithPanel(
      () => ref.read(syncServiceProvider).syncNow(mode: mode, progress: _progress),
    );
  }

  Future<void> _exportToFile() async {
    final doc = await ref.read(appDataServiceProvider).exportDocument();
    String message;
    try {
      message = await shareExportFile(doc) ? '書き出しました' : '書き出しをやめました';
    } on FormatException catch (error) {
      message = error.message;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _importFromFile() async {
    final String? path;
    try {
      path = await pickImportFile();
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
      return;
    }
    if (path == null || !mounted) return;
    _progress.start(SyncKind.file);
    await _runWithPanel(() async {
      final Map<String, dynamic> json;
      try {
        json = await readImportJson(path!);
      } on FormatException catch (error) {
        // A file the user picked themselves: say what is wrong with *it*,
        // rather than the generic "PC から受け取ったデータを読めませんでした".
        _progress.fail('corrupt', error.message);
        return SyncFailed('corrupt', error.message);
      }
      return ref.read(syncServiceProvider).applyReceived(json, progress: _progress);
    });
  }

  Future<void> _restoreBackup() async {
    final restored = await ref.read(syncServiceProvider).restoreBackup();
    if (restored) {
      ref.invalidate(taskMasterControllerProvider);
      ref.invalidate(dailyPlanControllerProvider);
    }
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(restored ? '同期前の状態に戻しました' : '戻せる控えがありません')),
    );
  }

  Future<void> _unpair() async {
    await ref.read(syncSettingsStoreProvider).clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('PC と同期')),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _statusCard(settings),
                const SizedBox(height: 16),
                _lanCard(settings),
                const SizedBox(height: 16),
                _offlineCard(),
                if (_hasBackup) ...<Widget>[
                  const SizedBox(height: 16),
                  _backupCard(),
                ],
                if (_isMac) ...<Widget>[
                  const SizedBox(height: 16),
                  const McpGuideSection(),
                ],
              ],
            ),
    );
  }

  Widget _statusCard(SyncSettings s) => Card(
    child: Column(
      children: <Widget>[
        ListTile(
          title: const Text('接続状態'),
          subtitle: Text(
            s.isPaired
                ? '${s.host}:${s.port}（${s.hubDeviceId ?? 'hub'}）'
                : '未ペアリング',
          ),
        ),
        if (s.isPaired)
          ListTile(
            title: const Text('最終同期'),
            subtitle: Text(
              s.lastSyncAt == null
                  ? 'まだ同期していません'
                  : DateFormat('yyyy/MM/dd HH:mm').format(s.lastSyncAt!.toLocal()),
            ),
          ),
        ListTile(
          title: const Text('この端末の ID'),
          subtitle: Text(ref.read(deviceClockProvider).deviceId),
        ),
      ],
    ),
  );

  Widget _lanCard(SyncSettings s) => Card(
    child: Column(
      children: <Widget>[
        if (s.isPaired)
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('今すぐ同期'),
            subtitle: const Text('同じ Wi-Fi の PC と双方向に同期します'),
            // Disabled rather than silently answering `busy`: a button that
            // does nothing without saying why is worse than a greyed-out one.
            enabled: !_running,
            onTap: () => _runWithPanel(
              () => ref.read(syncServiceProvider).syncNow(progress: _progress),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: Text(s.isPaired ? 'ペアリングし直す' : 'PC とペアリング'),
          subtitle: const Text('PC の画面の QR を読み取ります'),
          onTap: () async {
            await context.push<void>('/sync/pair');
            await _reload();
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit),
          title: const Text('接続先を手入力'),
          subtitle: const Text('エミュレーターや IP が変わったとき'),
          onTap: () => _editHost(s),
        ),
        if (s.isPaired)
          ListTile(
            leading: const Icon(Icons.link_off),
            title: const Text('ペアリングを解除'),
            subtitle: const Text('この端末に保存した接続情報を消します'),
            onTap: _unpair,
          ),
      ],
    ),
  );

  Widget _offlineCard() => Card(
    child: Column(
      children: <Widget>[
        const ListTile(
          title: Text('ネットワークが違うとき'),
          subtitle: Text('QR かファイルでやり取りします'),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code),
          title: const Text('QR で受け取る'),
          subtitle: const Text('PC の QR 画面にカメラを向けます'),
          onTap: () async {
            await context.push<void>('/sync/qr');
            await _reload();
          },
        ),
        ListTile(
          leading: const Icon(Icons.ios_share),
          title: const Text('PC へ書き出す'),
          subtitle: const Text('共有シートで JSON を渡します。アプリ自身は送信しません'),
          onTap: _exportToFile,
        ),
        if (_isMac)
          ListTile(
            leading: const Icon(Icons.file_open),
            title: const Text('ファイルから取り込む'),
            subtitle: const Text('スマホが書き出した JSON をマージします'),
            onTap: _importFromFile,
          ),
      ],
    ),
  );

  Widget _backupCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.settings_backup_restore),
      title: const Text('直前の同期前に戻す'),
      subtitle: const Text('置き換えで消えたこの端末のデータを 1 回だけ戻せます'),
      onTap: _restoreBackup,
    ),
  );

  Future<void> _editHost(SyncSettings s) async {
    final host = TextEditingController(text: s.host ?? '10.0.2.2');
    final port = TextEditingController(text: '${s.port}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接続先'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: host,
              decoration: const InputDecoration(labelText: 'ホスト（IP）'),
            ),
            TextField(
              controller: port,
              decoration: const InputDecoration(labelText: 'ポート'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final newHost = host.text.trim();
    final newPort = int.tryParse(port.text) ?? s.port;
    host.dispose();
    port.dispose();
    if (ok != true) return;
    await ref.read(syncSettingsStoreProvider).save(
      s.copyWith(host: newHost, port: newPort),
    );
    await _reload();
  }
}
