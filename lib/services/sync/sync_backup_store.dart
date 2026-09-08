import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final syncBackupStoreProvider = Provider<SyncBackupStore>((ref) => SyncBackupStore());

/// The one snapshot taken immediately before a replace overwrites local data.
///
/// `take_hub` and `take_phone` (and a restore from a file) discard whichever
/// side loses, and the user only finds out afterwards. Keeping the last
/// pre-replace export on the device turns that from "gone" into "one tap
/// back". Exactly one snapshot is kept: a stack of them would be a second
/// copy of the database to keep consistent, and the case that actually
/// happens is regret about the sync that just ran.
class SyncBackupStore {
  static const key = 'sync_backup_v1';

  Future<void> save(Map<String, dynamic> document) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(document));
  }

  Future<bool> exists() async =>
      ((await SharedPreferences.getInstance()).getString(key) ?? '').isNotEmpty;

  /// The stored document, or null when there is none. A snapshot that no
  /// longer parses is treated as absent rather than thrown at the caller —
  /// there is nothing a user can do about it, and the restore button simply
  /// stays away.
  Future<Map<String, dynamic>?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(key);
}
