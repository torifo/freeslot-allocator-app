import 'hlc.dart';

/// Sync bookkeeping carried by every entity (schema v2).
class SyncMeta {
  const SyncMeta({
    required this.clock,
    required this.updatedAt,
    this.deletedAt,
    this.migrated = false,
    this.extra = const <String, dynamic>{},
  });

  static const List<String> keys = <String>['clock', 'updatedAt', 'deletedAt', 'migrated'];
  static final DateTime epoch = DateTime.utc(1970);

  final Hlc clock;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final bool migrated;
  /// Unknown keys preserved verbatim so a newer schema is not destroyed.
  final Map<String, dynamic> extra;

  bool get isDeleted => deletedAt != null;

  factory SyncMeta.stamp(Hlc clock, DateTime now) =>
      SyncMeta(clock: clock, updatedAt: now.toUtc());

  SyncMeta touch(Hlc clock, DateTime now) =>
      SyncMeta(clock: clock, updatedAt: now.toUtc(), deletedAt: deletedAt, extra: extra);

  SyncMeta tombstone(Hlc clock, DateTime now) =>
      SyncMeta(clock: clock, updatedAt: now.toUtc(), deletedAt: now.toUtc(), extra: extra);

  /// Reads meta from an entity map. Missing keys mean the record predates v2;
  /// they are filled with the deterministic migrated sentinel so both devices
  /// derive the same value. [knownKeys] are the entity's own fields; anything
  /// else (except meta keys) is kept in [extra].
  factory SyncMeta.fromJson(Map<String, dynamic> json, {Set<String> knownKeys = const <String>{}}) {
    final rawClock = json['clock'];
    final clock = rawClock is String ? (Hlc.tryParse(rawClock) ?? Hlc.migrated) : Hlc.migrated;
    final rawUpdated = json['updatedAt'];
    final updatedAt = rawClock is String && rawUpdated is String
        ? (DateTime.tryParse(rawUpdated)?.toUtc() ?? epoch)
        : epoch;
    final rawDeleted = json['deletedAt'];
    final deletedAt = rawDeleted is String ? DateTime.tryParse(rawDeleted)?.toUtc() : null;
    final migrated = rawClock is! String || (json['migrated'] as bool? ?? false);
    // Unknown-key preservation only matters for records that already carry a
    // real v2 clock; a v1 record's non-meta fields are just its own entity
    // fields (e.g. id, name), not future-schema extras, so leave extra empty.
    final extra = rawClock is String
        ? <String, dynamic>{
            for (final entry in json.entries)
              if (!knownKeys.contains(entry.key) && !keys.contains(entry.key)) entry.key: entry.value,
          }
        : <String, dynamic>{};
    return SyncMeta(
      clock: clock,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
      migrated: migrated,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extra,
        'clock': clock.toString(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'deletedAt': deletedAt?.toUtc().toIso8601String(),
        'migrated': migrated,
      };
}
