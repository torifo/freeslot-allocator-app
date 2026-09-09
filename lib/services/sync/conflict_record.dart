import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/sync_meta.dart';

/// `cf-<sha256(entityId \n winnerClock \n loserClock)[0..16]>` — byte for byte
/// the same rule as `conflictId` in tools/hub/src/model.ts.
///
/// Derived from content and never from time, so Dart and TypeScript detecting
/// the same conflict independently produce the same id, re-detection is
/// idempotent, and the shared fixtures can pin an exact expected id.
String conflictId(String entityId, String winnerClock, String loserClock) =>
    'cf-${sha256.convert(utf8.encode('$entityId\n$winnerClock\n$loserClock')).toString().substring(0, 16)}';

/// Which half of the pair a version came from, derived from the HLC device id
/// and never from which merge argument carried it — byte for byte the same rule
/// as `sideOfDevice` in tools/hub/src/model.ts. `hub-…` is the MCP hub, `web-…`
/// a browser the hub serves, and everything else — an unparsable clock
/// included — is a phone.
String sideOfDevice(String deviceId) {
  if (deviceId.startsWith('hub-')) return 'hub';
  if (deviceId.startsWith('web-')) return 'web';
  return 'device';
}

/// True for the sides the user reads as 「PC 版」: the hub itself and the
/// browser it serves.
bool isPcSide(String side) => side == 'hub' || side == 'web';

/// One of the two versions that were in conflict, kept whole.
class ConflictSide {
  const ConflictSide({
    required this.side,
    required this.deviceId,
    required this.clock,
    required this.updatedAt,
    required this.snapshot,
    this.extra = const <String, dynamic>{},
  });

  /// `'hub'` / `'web'` / `'device'`, per [sideOfDevice]. Kept as a String, not
  /// an enum: an unknown value from a newer build must survive the round trip
  /// rather than be erased.
  final String side;
  final String deviceId;

  /// The raw HLC string. Not parsed into an [Hlc]: keeping the text means the
  /// record round-trips without changing shape, whatever the other side wrote.
  final String clock;

  /// The raw `updatedAt` text of that version, for the same reason.
  final String updatedAt;

  /// The whole record as it stood on that side. A deleted version carries the
  /// tombstone shape (`{id, clock, updatedAt, deletedAt}`).
  final Map<String, dynamic> snapshot;

  /// Keys a newer build wrote that this one does not know, kept verbatim so the
  /// round trip does not quietly delete them — the same reason [side] and
  /// `entityType` are Strings rather than enums.
  final Map<String, dynamic> extra;

  static const Set<String> _knownKeys = <String>{
    'side', 'deviceId', 'clock', 'updatedAt', 'snapshot',
  };

  bool get isDeleted => snapshot['deletedAt'] is String;

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...extra,
    'side': side,
    'deviceId': deviceId,
    'clock': clock,
    'updatedAt': updatedAt,
    'snapshot': snapshot,
  };

  factory ConflictSide.fromJson(Map<String, dynamic> json, {bool strict = false}) {
    String text(String key) {
      final value = json[key];
      if (value is String) return value;
      if (strict) throw FormatException('$key must be a String, got $value');
      return '';
    }

    final rawSnapshot = json['snapshot'];
    if (strict && rawSnapshot is! Map<String, dynamic>) {
      throw FormatException('snapshot must be a JSON object, got $rawSnapshot');
    }
    return ConflictSide(
      side: text('side'),
      deviceId: text('deviceId'),
      clock: text('clock'),
      updatedAt: text('updatedAt'),
      snapshot: rawSnapshot is Map<String, dynamic>
          ? Map<String, dynamic>.from(rawSnapshot)
          : <String, dynamic>{},
      extra: <String, dynamic>{
        for (final entry in json.entries)
          if (!_knownKeys.contains(entry.key)) entry.key: entry.value,
      },
    );
  }
}

/// The losing side of an LWW decision, kept so the user can still choose it.
///
/// The record itself carries [meta], so it is an ordinary entity as far as the
/// merge is concerned: two devices that both hold it converge on the larger
/// clock, and a resolution — which bumps the clock — therefore wins.
class ConflictRecord {
  const ConflictRecord({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.detectedAt,
    required this.detectedBy,
    required this.winner,
    required this.loser,
    required this.meta,
    this.resolution,
    this.resolvedAt,
    this.resolvedBy,
  });

  /// The record's own field names, excluding [SyncMeta.keys]. The set must stay
  /// identical to `ENTITY_KEYS.conflict` in tools/hub/src/model.ts: it decides
  /// which keys `contentHash` sees, and a mismatch would split the hash between
  /// the two languages.
  static const Set<String> jsonKeys = <String>{
    'id', 'entityType', 'entityId', 'detectedAt', 'detectedBy',
    'winner', 'loser', 'resolution', 'resolvedAt', 'resolvedBy',
  };

  final String id;

  /// A String, not an enum: a newer app may record a type this build cannot
  /// draw, and dropping it would delete the other side's record.
  final String entityType;
  final String entityId;
  final String detectedAt;
  final String detectedBy;
  final ConflictSide winner;
  final ConflictSide loser;

  /// `hub` / `device` / `current` / `superseded`, or anything a newer build
  /// wrote. Unknown values are kept for the same reason as [entityType].
  final String? resolution;
  final String? resolvedAt;
  final String? resolvedBy;
  final SyncMeta meta;

  /// Still waiting for the user. A tombstoned record is never open.
  bool get isOpen => resolution == null && !meta.isDeleted;

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...meta.toJson(),
    'id': id,
    'entityType': entityType,
    'entityId': entityId,
    'detectedAt': detectedAt,
    // Optional on the wire (`detectedBy: z.string().optional()` on the hub), so
    // a record that arrived without it goes back out without it: writing `''`
    // instead would change the content hash and split the two languages'
    // tie-break on the very same record.
    if (detectedBy.isNotEmpty) 'detectedBy': detectedBy,
    'winner': winner.toJson(),
    'loser': loser.toJson(),
    'resolution': resolution,
    'resolvedAt': resolvedAt,
    'resolvedBy': resolvedBy,
  };

  factory ConflictRecord.fromJson(Map<String, dynamic> json, {bool strict = false}) {
    String text(String key) {
      final value = json[key];
      if (value is String) return value;
      if (strict) throw FormatException('$key must be a String, got $value');
      return '';
    }

    String? maybe(String key) {
      final value = json[key];
      if (value is String) return value;
      if (strict && value != null) {
        throw FormatException('$key must be a String or null, got $value');
      }
      return null;
    }

    ConflictSide side(String key) {
      final value = json[key];
      if (value is Map<String, dynamic>) {
        return ConflictSide.fromJson(value, strict: strict);
      }
      if (strict) throw FormatException('$key must be a JSON object, got $value');
      return const ConflictSide(
        side: '', deviceId: '', clock: '', updatedAt: '', snapshot: <String, dynamic>{},
      );
    }

    return ConflictRecord(
      id: text('id'),
      entityType: text('entityType'),
      entityId: text('entityId'),
      detectedAt: text('detectedAt'),
      // Optional even in strict mode: the hub's zod schema marks it optional,
      // so a record that legitimately omits it must not be rejected here.
      detectedBy: maybe('detectedBy') ?? '',
      winner: side('winner'),
      loser: side('loser'),
      resolution: maybe('resolution'),
      resolvedAt: maybe('resolvedAt'),
      resolvedBy: maybe('resolvedBy'),
      meta: SyncMeta.fromJson(json, knownKeys: jsonKeys),
    );
  }

  /// [clearResolution] reopens a record: `resolution: null` alone cannot, since
  /// a null argument is indistinguishable from an omitted one.
  ConflictRecord copyWith({
    String? resolution,
    String? resolvedAt,
    String? resolvedBy,
    SyncMeta? meta,
    bool clearResolution = false,
  }) => ConflictRecord(
    id: id,
    entityType: entityType,
    entityId: entityId,
    detectedAt: detectedAt,
    detectedBy: detectedBy,
    winner: winner,
    loser: loser,
    resolution: clearResolution ? null : (resolution ?? this.resolution),
    resolvedAt: clearResolution ? null : (resolvedAt ?? this.resolvedAt),
    resolvedBy: clearResolution ? null : (resolvedBy ?? this.resolvedBy),
    meta: meta ?? this.meta,
  );
}
