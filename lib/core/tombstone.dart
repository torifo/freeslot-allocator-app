import 'sync_meta.dart';

/// A deleted entity: only its id and sync meta survive.
class Tombstone {
  const Tombstone({required this.id, required this.meta});

  final String id;
  final SyncMeta meta;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, ...meta.toJson()};

  factory Tombstone.fromJson(Map<String, dynamic> json) {
    final meta = SyncMeta.fromJson(json, knownKeys: const {'id'});
    if (!meta.isDeleted) {
      throw const FormatException('Tombstone without deletedAt');
    }
    return Tombstone(id: json['id'] as String, meta: meta);
  }
}

class SplitRecords {
  const SplitRecords({required this.live, required this.tombstones});

  final List<Map<String, dynamic>> live;
  final List<Tombstone> tombstones;
}

/// Splits a JSON array into live entity maps and tombstones.
///
/// In [strict] mode any entry that is not an object, or a tombstone that cannot
/// be parsed, throws a [FormatException] so a sync never silently drops data.
/// Otherwise bad entries are skipped, which is the behaviour startup relies on.
SplitRecords splitDeleted(dynamic raw, {required bool strict}) {
  final live = <Map<String, dynamic>>[];
  final tombstones = <Tombstone>[];
  if (raw is! List) {
    if (strict && raw != null) {
      throw const FormatException('Expected a JSON array');
    }
    return SplitRecords(live: live, tombstones: tombstones);
  }
  for (final dynamic entry in raw) {
    if (entry is! Map<String, dynamic>) {
      if (strict) throw FormatException('Expected an object, got $entry');
      continue;
    }
    if (entry['deletedAt'] is String) {
      try {
        tombstones.add(Tombstone.fromJson(entry));
      } on FormatException {
        if (strict) rethrow;
      }
      continue;
    }
    live.add(entry);
  }
  return SplitRecords(live: live, tombstones: tombstones);
}

/// Parses each live map with [parse]; strict mode rethrows parse failures.
List<T> parseLive<T>(
  List<Map<String, dynamic>> live,
  T Function(Map<String, dynamic>) parse, {
  required bool strict,
}) {
  final items = <T>[];
  for (final entry in live) {
    try {
      items.add(parse(entry));
    } catch (error) {
      if (strict) throw FormatException('Corrupt record ${entry['id']}: $error');
    }
  }
  return items;
}

/// True when no id appears both as a live record and as a tombstone.
///
/// A live record and a tombstone sharing an id would serialize twice into the
/// same array and let a peer resurrect or re-delete the record at random.
bool idsDisjoint(Iterable<String> liveIds, Iterable<Tombstone> tombstones) {
  final live = liveIds.toSet();
  return !tombstones.any((item) => live.contains(item.id));
}

/// Drops every tombstone whose id is in [liveIds], so a re-added record never
/// coexists with its own tombstone.
List<Tombstone> withoutTombstonesFor(
  Iterable<Tombstone> tombstones,
  Iterable<String> liveIds,
) {
  final live = liveIds.toSet();
  return tombstones.where((item) => !live.contains(item.id)).toList();
}
