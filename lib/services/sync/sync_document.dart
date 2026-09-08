import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';

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
  });

  static const int schemaVersion = 2;

  final DateTime exportedAt;
  final String deviceId;
  final DateTime? lastSyncAt;
  final DateTime? purgedBefore;
  final TaskMasterStateData taskMaster;
  final DailyPlanStateData dailyPlan;

  int get version => schemaVersion;

  SyncDocument copyWith({
    DateTime? exportedAt,
    String? deviceId,
    DateTime? lastSyncAt,
    DateTime? purgedBefore,
    TaskMasterStateData? taskMaster,
    DailyPlanStateData? dailyPlan,
  }) {
    return SyncDocument(
      exportedAt: exportedAt ?? this.exportedAt,
      deviceId: deviceId ?? this.deviceId,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      purgedBefore: purgedBefore ?? this.purgedBefore,
      taskMaster: taskMaster ?? this.taskMaster,
      dailyPlan: dailyPlan ?? this.dailyPlan,
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
  };

  /// Reads a v1 or v2 envelope. v1 used snake_case keys and carried no device
  /// id, so it is attributed to the deterministic `migrated` device.
  factory SyncDocument.fromJson(
    Map<String, dynamic> json, {
    bool strict = false,
  }) {
    final rawVersion = json['version'];
    final version = rawVersion is int ? rawVersion : 1;
    if (version > schemaVersion) {
      throw UnsupportedSchemaException(version);
    }
    final isV1 = version < schemaVersion;
    Map<String, dynamic> section(String key) {
      final value = json[key];
      return value is Map<String, dynamic> ? value : const <String, dynamic>{};
    }

    final taskJson = section(isV1 ? 'task_master' : 'taskMaster');
    final planJson = section(isV1 ? 'daily_plan' : 'dailyPlan');
    final exportedRaw = json[isV1 ? 'exported_at' : 'exportedAt'];
    return SyncDocument(
      exportedAt:
          DateTime.tryParse(exportedRaw is String ? exportedRaw : '')?.toUtc() ??
          DateTime.utc(1970),
      deviceId: isV1
          ? 'migrated'
          : (json['deviceId'] is String ? json['deviceId'] as String : 'unknown'),
      lastSyncAt: _parseUtc(json['lastSyncAt']),
      purgedBefore: _parseUtc(json['purgedBefore']),
      taskMaster: TaskMasterStateData.fromJson(taskJson, strict: strict),
      dailyPlan: DailyPlanStateData.fromJson(planJson, strict: strict),
    );
  }

  static DateTime? _parseUtc(dynamic value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
