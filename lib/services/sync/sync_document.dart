import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'conflict_record.dart';

/// Thrown when a payload was written by a newer schema than this build knows.
///
/// Refusing is deliberate: a silent partial read would drop the fields this
/// build cannot see and then write them away on the next sync.
class UnsupportedSchemaException implements Exception {
  const UnsupportedSchemaException(this.version);

  final int version;

  @override
  String toString() =>
      'Unsupported schema version $version '
      '(this app supports up to ${SyncDocument.schemaVersion})';
}

/// The whole-app payload exchanged between devices and written to data.json.
class SyncDocument {
  const SyncDocument({
    required this.exportedAt,
    required this.deviceId,
    required this.taskMaster,
    required this.dailyPlan,
    this.lastSyncAt,
    this.purgedBefore,
    this.conflicts = const <ConflictRecord>[],
  });

  static const int schemaVersion = 2;

  final DateTime exportedAt;
  final String deviceId;
  final DateTime? lastSyncAt;
  final DateTime? purgedBefore;
  final TaskMasterStateData taskMaster;
  final DailyPlanStateData dailyPlan;

  /// Conflict records (Plan 3b). Ordinary entities as far as the merge is
  /// concerned, so they live beside the payload rather than inside it.
  final List<ConflictRecord> conflicts;

  int get version => schemaVersion;

  SyncDocument copyWith({
    DateTime? exportedAt,
    String? deviceId,
    DateTime? lastSyncAt,
    DateTime? purgedBefore,
    TaskMasterStateData? taskMaster,
    DailyPlanStateData? dailyPlan,
    List<ConflictRecord>? conflicts,
  }) {
    return SyncDocument(
      exportedAt: exportedAt ?? this.exportedAt,
      deviceId: deviceId ?? this.deviceId,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      purgedBefore: purgedBefore ?? this.purgedBefore,
      taskMaster: taskMaster ?? this.taskMaster,
      dailyPlan: dailyPlan ?? this.dailyPlan,
      conflicts: conflicts ?? this.conflicts,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': schemaVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'deviceId': deviceId,
    'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
    'purgedBefore': purgedBefore?.toUtc().toIso8601String(),
    'taskMaster': taskMaster.toJson(),
    'dailyPlan': dailyPlan.toJson(),
    // Omitted entirely when empty: a document with nothing recorded stays
    // byte-identical to what a build without conflicts would have written.
    if (conflicts.isNotEmpty)
      'conflicts': conflicts.map((c) => c.toJson()).toList(),
  };

  /// Reads a v1 or v2 envelope. v1 used snake_case keys and carried no device
  /// id, so it is attributed to the deterministic `migrated` device.
  factory SyncDocument.fromJson(
    Map<String, dynamic> json, {
    bool strict = false,
  }) {
    final rawVersion = json['version'];
    if (strict && rawVersion is! int) {
      throw FormatException('version must be an int, got $rawVersion');
    }
    final version = rawVersion is int ? rawVersion : 1;
    if (version > schemaVersion) {
      throw UnsupportedSchemaException(version);
    }
    final isV1 = version < schemaVersion;
    Map<String, dynamic> section(String key) {
      final value = json[key];
      if (value is Map<String, dynamic>) return value;
      if (strict) {
        throw FormatException('$key must be a JSON object, got $value');
      }
      return const <String, dynamic>{};
    }

    final taskJson = section(isV1 ? 'task_master' : 'taskMaster');
    final planJson = section(isV1 ? 'daily_plan' : 'dailyPlan');
    final exportedRaw = json[isV1 ? 'exported_at' : 'exportedAt'];
    final exportedAt = DateTime.tryParse(
      exportedRaw is String ? exportedRaw : '',
    )?.toUtc();
    if (strict && exportedAt == null) {
      throw FormatException(
        'exportedAt missing or unparsable, got $exportedRaw',
      );
    }
    final rawDeviceId = json['deviceId'];
    if (strict && !isV1 && rawDeviceId is! String) {
      throw FormatException('deviceId must be a String, got $rawDeviceId');
    }
    return SyncDocument(
      exportedAt: exportedAt ?? DateTime.utc(1970),
      deviceId: isV1
          ? 'migrated'
          : (rawDeviceId is String ? rawDeviceId : 'unknown'),
      lastSyncAt: _parseUtc(json['lastSyncAt']),
      purgedBefore: _parseUtc(json['purgedBefore']),
      taskMaster: TaskMasterStateData.fromJson(taskJson, strict: strict),
      dailyPlan: DailyPlanStateData.fromJson(planJson, strict: strict),
      // Never an error, even in strict mode: a v2 document written before
      // Plan 3b simply has no such key, and that is not corruption.
      conflicts: _parseConflicts(json['conflicts'], strict: strict),
    );
  }

  static List<ConflictRecord> _parseConflicts(dynamic raw, {required bool strict}) {
    if (raw is! List) return const <ConflictRecord>[];
    final out = <ConflictRecord>[];
    for (final dynamic entry in raw) {
      if (entry is! Map<String, dynamic>) {
        if (strict) throw FormatException('conflicts entry must be an object, got $entry');
        continue;
      }
      out.add(ConflictRecord.fromJson(entry, strict: strict));
    }
    return out;
  }

  static DateTime? _parseUtc(dynamic value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
