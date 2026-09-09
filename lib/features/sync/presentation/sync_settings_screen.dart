import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/confirm_dialog.dart';
import '../../../core/device_clock.dart';
import '../../../services/app_data_service.dart';
import '../../../services/hub_mode/hub_mode.dart';
import '../../../services/storage/hub_backed_store.dart';
import '../../../services/sync/file_exporter.dart';
import '../../../services/sync/conflict_record.dart';
import '../../../services/sync/lan_sync_types.dart';
import '../../../services/sync/sync_progress.dart';
import '../../../services/sync/sync_service.dart';
import '../../../services/sync/sync_settings.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import '../../task_master/data/task_master_repository.dart' show stateStoreProvider;
import '../application/conflict_controller.dart';
import '../application/sync_in_flight.dart';
import 'mcp_guide_section.dart';
import 'sync_progress_panel.dart';
import 'sync_replace_dialog.dart';

/// 「PC と同期」— the one screen that owns every hand-off with the hub: LAN
/// sync, pairing, QR receive, file export and (on macOS) file import.
class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key, this.showWebGuide});

  /// Overrides the 「this is the public web build」 check, for tests.
  ///
  /// `kIsWeb` is a compile-time constant, so a test running on the VM can
  /// never make it true; the screen takes the answer as a parameter instead
  /// and falls back to the real check when nothing is passed.
  final bool? showWebGuide;

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  final SyncProgressController _progress = SyncProgressController();

  TextEditingController? _hostField;
  TextEditingController? _portField;

  SyncSettings? _settings;
  bool _hasBackup = false;
  bool _running = false;

  bool get _isMac => !kIsWeb && Platform.isMacOS;

  /// The public web build: no hub on the other end, so the MCP guide is the
  /// only thing on this screen that leads anywhere.
  bool get _showWebGuide => widget.showWebGuide ?? kIsWeb;

  /// Non-null only in the browser the hub itself serves.
  ///
  /// Read once: `readHubMode()` reaches into `window.__FRELOCATOR_HUB__` on
  /// every call, and the answer cannot change while the screen is mounted.
  HubMode? _hub;

  @override
  void initState() {
    super.initState();
    _hub = readHubMode();
    _reload();
  }

  @override
  void dispose() {
    _hostField?.dispose();
    _portField?.dispose();
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

  /// The sheet's own context, so a pop targets the sheet's route rather than
  /// whatever happens to be on top of this screen's navigator.
  BuildContext? _sheetContext;

  /// Pops the progress sheet, and only the progress sheet.
  ///
  /// `Navigator.of(screenContext).pop()` would take down whatever route is
  /// currently on top — a dialog the user opened over the sheet, or the screen
  /// itself once the sheet has already gone.
  void _closeSheet() {
    final ctx = _sheetContext;
    if (ctx == null || !ctx.mounted) return;
    final route = ModalRoute.of(ctx);
    if (route == null || !route.isCurrent) return;
    Navigator.of(ctx).pop();
  }

  /// Runs one sync-shaped operation behind the progress panel.
  ///
  /// The panel stays up until the user dismisses it, so a summary or an error
  /// is never flashed past them; only a `purged_before` answer closes it early,
  /// because that outcome is a question rather than a result.
  ///
  /// [kind] starts the progress controller *before* the sheet is built: a sheet
  /// that opens on `idle` shows a 閉じる button, and tapping it would walk away
  /// from a run that is about to start rather than cancel it.
  Future<void> _runWithPanel(
    SyncKind kind,
    Future<SyncOutcome> Function() run,
  ) async {
    if (_running) return;
    setState(() => _running = true);
    // Captured before the first await: after this widget is disposed `ref.read`
    // throws, and the `finally` below would never lower the flag — wedging the
    // foreground reload in `app.dart` forever.
    final inFlight = ref.read(syncInFlightProvider.notifier);
    inFlight.begin();
    _progress.start(kind);

    final Future<void> panel = showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) {
        _sheetContext = ctx;
        return ValueListenableBuilder<SyncProgress>(
          valueListenable: _progress,
          builder: (_, SyncProgress p, _) => PopScope<void>(
            // A back gesture during the run would leave the sync writing with
            // nothing on screen to say so; cancel is the way out instead.
            canPop: !p.isActive,
            child: SyncProgressPanel(
              controller: _progress,
              onCancel: _progress.cancel,
              onClose: _closeSheet,
              onOpenConflicts: () {
                _closeSheet();
                context.push('/sync/conflicts');
              },
            ),
          ),
        );
      },
    );

    SyncOutcome outcome;
    try {
      outcome = await run();
    } catch (error) {
      // Nothing below `SyncService` is supposed to throw, but a plugin or a
      // platform channel can; the panel must still land on a Japanese failure
      // rather than an uncaught exception and a bar that never stops.
      final message = syncErrorMessage('unknown');
      _progress.fail('unknown', message);
      outcome = SyncFailed('unknown', message);
    } finally {
      inFlight.end();
      if (mounted) setState(() => _running = false);
    }
    if (!mounted) return;

    if (outcome is SyncNeedsReplace) {
      _closeSheet();
      await panel;
      _sheetContext = null;
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
    _sheetContext = null;
  }

  Future<void> _askReplace(String message) async {
    final mode = await SyncReplaceDialog.show(context, message);
    if (mode == null || !mounted) return;
    await _runWithPanel(
      SyncKind.lan,
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
    await _runWithPanel(SyncKind.file, () async {
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
    final ok = await confirmAction(
      context,
      title: '同期前に戻す',
      message: '同期後にこの端末で行った変更は失われます。控えは 1 回しか使えません。',
      confirmLabel: '戻す',
    );
    if (!ok || !mounted) return;
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
    final ok = await confirmAction(
      context,
      title: 'ペアリングを解除',
      message: 'この端末に保存した接続情報を消します。'
          'もう一度同期するには PC の QR を読み直してください。',
      confirmLabel: '解除',
    );
    if (!ok) return;
    await ref.read(syncSettingsStoreProvider).clear();
    // The backup deliberately survives: it is this phone's own pre-sync state,
    // not part of the connection, and unpairing right after a bad sync is
    // exactly when the user still needs 直前の同期前に戻す.
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final hub = _hub;
    if (hub != null) {
      // In hub mode there is nothing to pair, export or import: this browser
      // *is* the PC's data file. Showing the LAN cards would offer to sync the
      // hub with itself.
      return Scaffold(
        appBar: AppBar(title: const Text('PC と同期')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[_hubCard(hub), const SizedBox(height: 16), _conflictCard()],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('PC と同期')),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _statusCard(settings),
                if (!settings.isPaired && (settings.host ?? '').isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _unpairedHostCard(),
                ],
                const SizedBox(height: 16),
                _lanCard(settings),
                const SizedBox(height: 16),
                _conflictCard(),
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
                if (_showWebGuide) ...<Widget>[
                  const SizedBox(height: 16),
                  const WebMcpGuideSection(),
                ],
              ],
            ),
    );
  }


  /// The way into the conflict list, with the open count as a badge.
  ///
  /// Always shown — in hub mode too, where the LAN cards are hidden: a browser
  /// editing the hub's document can be on either side of a conflict.
  Widget _conflictCard() {
    final records = ref.watch(conflictControllerProvider);
    // Still loading, or failed to load: the row is still the way in, it just
    // carries no badge yet.
    final count = records is AsyncData<List<ConflictRecord>>
        ? openConflicts(records.value).length
        : null;
    return Card(
      child: ListTile(
        title: const Text('競合'),
        subtitle: Text(
          // Nothing is known yet, so the row says nothing: claiming
          // 「未解決の競合はありません」 before the records have been read would
          // be a statement the screen cannot back up.
          count == null
              ? '未解決の競合を確認できます'
              : count == 0
              ? '未解決の競合はありません'
              : '未解決 $count 件。どちらの版を採用するか選べます。',
        ),
        trailing: count == null || count == 0
            ? const Icon(Icons.chevron_right)
            : Badge(label: Text('$count'), child: const Icon(Icons.chevron_right)),
        onTap: () => context.push('/sync/conflicts'),
      ),
    );
  }

  /// What the hub-served browser shows instead of the LAN / QR / file cards.
  Widget _hubCard(HubMode hub) {
    final store = ref.read(stateStoreProvider);
    final hubStore = store is HubBackedStore ? store : null;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('この PC のデータを直接編集しています', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'この画面は PC 側のハブが配信しているブラウザ版です。'
              '編集は PC のデータファイルにそのまま書き込まれ、ブラウザ側には控えを残しません。'
              '保存前にタブを閉じたりリロードしたりすると、その編集は失われます。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('保存先', style: theme.textTheme.labelLarge),
            SelectableText(
              hub.dataFile.isEmpty ? '（不明）' : hub.dataFile,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text('PC 側の識別子', style: theme.textTheme.labelLarge),
            SelectableText(hub.hubDeviceId, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
            if (hubStore != null) ...<Widget>[
              const SizedBox(height: 12),
              Text('最終保存', style: theme.textTheme.labelLarge),
              ValueListenableBuilder<bool>(
                valueListenable: hubStore.hasUnsentEdits,
                builder: (context, unsent, _) {
                  final savedAt = hubStore.lastSavedAt;
                  return Text(
                    unsent
                        ? '未保存の編集があります（再試行中）'
                        : savedAt == null
                        ? 'この画面を開いてからまだ保存していません'
                        : DateFormat('M/d HH:mm:ss').format(savedAt),
                    style: const TextStyle(fontSize: 12),
                  );
                },
              ),
              _hubTrouble(hubStore),
            ],
            const SizedBox(height: 12),
            const Text(
              'PC の Claude Code（MCP）からの編集は数秒でこの画面に反映されます。'
              'スマホとの同期は今までどおり PC 側のハブが引き受けます。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// The last push failure, or the hub's last warning when there was none.
  ///
  /// A terminal refusal (`purged_before`, `upgrade_required`, …) never clears
  /// itself, so it comes with the only two ways out: one side wins and the
  /// other side's work is thrown away.
  Widget _hubTrouble(HubBackedStore store) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<HubError?>(
      valueListenable: store.lastError,
      builder: (context, error, _) {
        if (error == null) {
          final warning = store.lastWarning;
          if (warning == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              warning,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                error.message,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
              if (error.terminal) ...<Widget>[
                const SizedBox(height: 4),
                const Text(
                  'このままでは保存できません。どちらのデータを残すか選んでください。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: () => _replaceHubData(store, HubReplace.takeHub),
                      child: const Text('PC のデータで置き換える'),
                    ),
                    OutlinedButton(
                      onPressed: () => _replaceHubData(store, HubReplace.takeWeb),
                      child: const Text('ブラウザのデータで置き換える'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Both directions lose something, so both spell out what.
  Future<void> _replaceHubData(HubBackedStore store, HubReplace choice) async {
    final takeHub = choice == HubReplace.takeHub;
    final ok = await confirmAction(
      context,
      title: 'どちらのデータを残しますか？',
      message: takeHub
          ? 'PC のデータでこの画面を置き換えます。'
                'ブラウザで編集してまだ保存できていない内容は失われます。'
          : 'ブラウザのデータで PC のデータを置き換えます。'
                'PC 側の変更（他の端末から届いた分も含む）は失われます。',
      confirmLabel: takeHub ? 'PC のデータで置き換える' : 'ブラウザのデータで置き換える',
    );
    if (!ok) return;
    try {
      await store.replaceWith(choice);
    } catch (_) {
      // `replaceWith` already put the reason on `lastError`; the card redraws
      // itself from the notifier.
    }
    if (!mounted) return;
    ref.invalidate(taskMasterControllerProvider);
    ref.invalidate(dailyPlanControllerProvider);
    setState(() {});
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

  /// A host was typed in but the pairing never happened.
  ///
  /// The two are separate steps and the screen used to show neither: 「未ペア
  /// リング」 above a filled-in 接続先 read like a contradiction rather than
  /// like a job half done (C-2).
  Widget _unpairedHostCard() => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.info_outline),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '接続先は設定済みですが、まだペアリングしていません。'
                  'PC のペアリング画面の QR を読み取るか、URL を手入力してください。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: () async {
                await context.push<void>('/sync/pair');
                await _reload();
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('ペアリングへ進む'),
            ),
          ),
        ],
      ),
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
              SyncKind.lan,
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
          subtitle: const Text('QR が読めないとき（PC の IP を直接入力）'),
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
    // Owned by the State, not by this method: the dialog's exit animation keeps
    // rebuilding the fields for a few frames after `showDialog` has answered,
    // and a controller disposed on the way out would be used after disposal.
    final host = _hostField ??= TextEditingController();
    final port = _portField ??= TextEditingController();
    // Empty, with the shape of an address as a hint: `10.0.2.2` is the
    // Android emulator's view of its host machine and meant nothing to anyone
    // holding a real phone (C-2 / I-8).
    host.text = s.host ?? '';
    port.text = '${s.port == 0 ? 47820 : s.port}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // Validated in the dialog rather than swallowed on the way out: an
          // empty host or a port outside 1..65535 cannot be dialled at all, and
          // silently keeping the old value would look like the edit was saved.
          final hostError = hostValidationError(host.text);
          final parsed = int.tryParse(port.text.trim());
          final portError = parsed == null || parsed < 1 || parsed > 65535
              ? 'ポートは 1〜65535 の数字です'
              : null;
          return AlertDialog(
            // Scrollable so the keyboard pushes the fields rather than hiding
            // the title behind itself (M-16).
            scrollable: true,
            title: const Text('接続先'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: host,
                  autocorrect: false,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: 'ホスト（IP）',
                    hintText: '192.168.x.x',
                    errorText: hostError,
                    errorMaxLines: 2,
                  ),
                ),
                TextField(
                  controller: port,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: 'ポート',
                    hintText: '47820',
                    errorText: portError,
                    errorMaxLines: 2,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: hostError == null && portError == null
                    ? () => Navigator.of(ctx).pop(true)
                    : null,
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    final newHost = host.text.trim();
    final newPort = int.tryParse(port.text.trim());
    if (ok != true) return;
    if (hostValidationError(newHost) != null ||
        newPort == null ||
        newPort < 1 ||
        newPort > 65535) {
      return;
    }
    await ref.read(syncSettingsStoreProvider).save(
      s.copyWith(host: newHost, port: newPort),
    );
    await _reload();
    if (!mounted) return;
    // Saving used to leave the dialog and say nothing at all (C-2).
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('接続先を保存しました')));
  }
}

/// An IPv4 or IPv6 address, or a host name of the shape a LAN actually hands
/// out — the value is dialled directly, so anything else can only fail later,
/// at a point where the error says 「PC に接続できません」 and blames the network.
///
/// Surrounding whitespace is trimmed rather than rejected: it is what a paste
/// from a terminal or a chat message carries, and telling the user off for it
/// when the fix is obvious helps nobody (I-3).
final RegExp _ipv4 = RegExp(
  r'^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
);

/// Anything made only of digits and dots is meant to be an IPv4 address, so it
/// is held to [_ipv4] rather than being waved through as a host name — the
/// hostname grammar happily accepts `999.999.999.999` and `192.168` (I-4).
final RegExp _dottedDigits = RegExp(r'^[\d.]+$');
final RegExp _hostname = RegExp(
  r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$',
);

/// Deliberately loose: the shapes IPv6 takes (`::1`, `fe80::1%en0`-less
/// literals, an embedded IPv4 tail) are more than a regexp should arbitrate
/// here, and the socket rejects a wrong one with a clear error anyway.
final RegExp _ipv6ish = RegExp(r'^[0-9A-Fa-f:.]+$');

/// Why [raw] cannot be used as a hub address, or null when it can.
String? hostValidationError(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return 'ホストを入力してください';
  const message = 'IP アドレス（192.168.x.x）かホスト名を入力してください';
  // Brackets are how an IPv6 literal is written next to a port; the address
  // itself is what gets dialled.
  final bare = value.startsWith('[') && value.endsWith(']')
      ? value.substring(1, value.length - 1)
      : value;
  if (bare.contains(':')) {
    return _ipv6ish.hasMatch(bare) && !bare.contains(':::') ? null : message;
  }
  if (_dottedDigits.hasMatch(bare)) {
    return _ipv4.hasMatch(bare) ? null : message;
  }
  return _hostname.hasMatch(bare) ? null : message;
}
