import 'dart:convert';

import '../../../core/hlc.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';

export '../../../core/tombstone.dart' show Tombstone;

enum TaskKind { mustDo, wantToDo }

extension TaskKindX on TaskKind {
  String get label {
    switch (this) {
      case TaskKind.mustDo:
        return 'やるべきこと';
      case TaskKind.wantToDo:
        return 'やりたいこと';
    }
  }

  String get storageKey {
    switch (this) {
      case TaskKind.mustDo:
        return 'must_do';
      case TaskKind.wantToDo:
        return 'want_to_do';
    }
  }

  static TaskKind fromStorageKey(String value) {
    return TaskKind.values.firstWhere(
      (kind) => kind.storageKey == value,
      orElse: () => TaskKind.mustDo,
    );
  }
}

class TaskCategory {
  TaskCategory({required this.id, required this.name, SyncMeta? meta})
    : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = <String>{'id', 'name'};

  final String id;
  final String name;
  final SyncMeta meta;

  TaskCategory copyWith({String? id, String? name, SyncMeta? meta}) {
    return TaskCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      meta: meta ?? this.meta,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    ...meta.toJson(),
  };

  factory TaskCategory.fromJson(Map<String, dynamic> json) {
    return TaskCategory(
      id: json['id'] as String,
      name: json['name'] as String,
      meta: SyncMeta.fromJson(json, knownKeys: jsonKeys),
    );
  }
}

class TaskMaster {
  TaskMaster({
    required this.id,
    required this.title,
    required this.kind,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.memo = '',
    this.categoryId,
    this.estimatedMinutes = 0,
    SyncMeta? meta,
  }) : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = <String>{
    'id',
    'title',
    'kind',
    'priority',
    'createdAt',
    'memo',
    'categoryId',
    'estimatedMinutes',
  };

  final String id;
  final String title;
  final TaskKind kind;
  final int priority;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String memo;
  final String? categoryId;
  final int estimatedMinutes;
  final SyncMeta meta;

  TaskMaster copyWith({
    String? id,
    String? title,
    TaskKind? kind,
    int? priority,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? memo,
    String? categoryId,
    bool clearCategory = false,
    int? estimatedMinutes,
    SyncMeta? meta,
  }) {
    return TaskMaster(
      id: id ?? this.id,
      title: title ?? this.title,
      kind: kind ?? this.kind,
      priority: priority ?? this.priority,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      memo: memo ?? this.memo,
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      meta: meta ?? this.meta,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'kind': kind.storageKey,
    'priority': priority,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'memo': memo,
    'categoryId': categoryId,
    'estimatedMinutes': estimatedMinutes,
    ...meta.toJson(),
    // updatedAt は meta 側の値を正とし、表示用フィールドと二重管理しない。
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory TaskMaster.fromJson(Map<String, dynamic> json) {
    final meta = SyncMeta.fromJson(json, knownKeys: jsonKeys);
    final updatedAt = DateTime.parse(json['updatedAt'] as String).toUtc();
    return TaskMaster(
      id: json['id'] as String,
      title: json['title'] as String,
      kind: TaskKindX.fromStorageKey(json['kind'] as String),
      priority: json['priority'] as int? ?? 3,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: updatedAt,
      memo: json['memo'] as String? ?? '',
      categoryId: json['categoryId'] as String?,
      estimatedMinutes: json['estimatedMinutes'] as int? ?? 0,
      meta: meta.migrated
          ? SyncMeta(
              clock: Hlc.migrated,
              updatedAt: updatedAt,
              migrated: true,
              extra: meta.extra,
            )
          : meta,
    );
  }
}

enum CategoryMergeStrategy { keepShorter, keepLonger, keepMustDo, keepWantToDo }

extension CategoryMergeStrategyX on CategoryMergeStrategy {
  String get label {
    switch (this) {
      case CategoryMergeStrategy.keepShorter:
        return '少ない方に合わせる';
      case CategoryMergeStrategy.keepLonger:
        return '多い方に合わせる';
      case CategoryMergeStrategy.keepMustDo:
        return 'やるべきこと側に合わせる';
      case CategoryMergeStrategy.keepWantToDo:
        return 'やりたいこと側に合わせる';
    }
  }
}

class TaskMasterStateData {
  TaskMasterStateData({
    required List<TaskMaster> tasks,
    required List<TaskCategory> mustDoCategories,
    required List<TaskCategory> wantToDoCategories,
    required this.shareCategories,
    SyncMeta? settingsMeta,
    List<Tombstone> deletedTasks = const <Tombstone>[],
    List<Tombstone> deletedMustDoCategories = const <Tombstone>[],
    List<Tombstone> deletedWantToDoCategories = const <Tombstone>[],
  }) : tasks = List<TaskMaster>.unmodifiable(tasks),
       mustDoCategories = List<TaskCategory>.unmodifiable(mustDoCategories),
       wantToDoCategories = List<TaskCategory>.unmodifiable(wantToDoCategories),
       settingsMeta = settingsMeta ?? SyncMeta.migratedDefault,
       deletedTasks = List<Tombstone>.unmodifiable(deletedTasks),
       deletedMustDoCategories = List<Tombstone>.unmodifiable(
         deletedMustDoCategories,
       ),
       deletedWantToDoCategories = List<Tombstone>.unmodifiable(
         deletedWantToDoCategories,
       );

  final List<TaskMaster> tasks;
  final List<TaskCategory> mustDoCategories;
  final List<TaskCategory> wantToDoCategories;
  final bool shareCategories;
  final SyncMeta settingsMeta;
  final List<Tombstone> deletedTasks;
  final List<Tombstone> deletedMustDoCategories;
  final List<Tombstone> deletedWantToDoCategories;

  factory TaskMasterStateData.initial() {
    return TaskMasterStateData(
      tasks: const <TaskMaster>[],
      mustDoCategories: <TaskCategory>[
        TaskCategory(id: 'must-work', name: '仕事'),
        TaskCategory(id: 'must-housework', name: '家事'),
        TaskCategory(id: 'must-admin', name: '雑務'),
      ],
      wantToDoCategories: <TaskCategory>[
        TaskCategory(id: 'want-hobby', name: '趣味'),
        TaskCategory(id: 'want-learning', name: '学習'),
        TaskCategory(id: 'want-health', name: '健康'),
      ],
      shareCategories: false,
    );
  }

  TaskMasterStateData copyWith({
    List<TaskMaster>? tasks,
    List<TaskCategory>? mustDoCategories,
    List<TaskCategory>? wantToDoCategories,
    bool? shareCategories,
    SyncMeta? settingsMeta,
    List<Tombstone>? deletedTasks,
    List<Tombstone>? deletedMustDoCategories,
    List<Tombstone>? deletedWantToDoCategories,
  }) {
    return TaskMasterStateData(
      tasks: tasks ?? this.tasks,
      mustDoCategories: mustDoCategories ?? this.mustDoCategories,
      wantToDoCategories: wantToDoCategories ?? this.wantToDoCategories,
      shareCategories: shareCategories ?? this.shareCategories,
      settingsMeta: settingsMeta ?? this.settingsMeta,
      deletedTasks: deletedTasks ?? this.deletedTasks,
      deletedMustDoCategories:
          deletedMustDoCategories ?? this.deletedMustDoCategories,
      deletedWantToDoCategories:
          deletedWantToDoCategories ?? this.deletedWantToDoCategories,
    );
  }

  List<TaskCategory> categoriesFor(TaskKind kind) {
    return kind == TaskKind.mustDo ? mustDoCategories : wantToDoCategories;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tasks': <Map<String, dynamic>>[
      ...tasks.map((task) => task.toJson()),
      ...deletedTasks.map((item) => item.toJson()),
    ],
    'mustDoCategories': <Map<String, dynamic>>[
      ...mustDoCategories.map((category) => category.toJson()),
      ...deletedMustDoCategories.map((item) => item.toJson()),
    ],
    'wantToDoCategories': <Map<String, dynamic>>[
      ...wantToDoCategories.map((category) => category.toJson()),
      ...deletedWantToDoCategories.map((item) => item.toJson()),
    ],
    'settings': <String, dynamic>{
      'shareCategories': shareCategories,
      ...settingsMeta.toJson(),
    },
  };

  String encode() => jsonEncode(toJson());

  factory TaskMasterStateData.fromJson(
    Map<String, dynamic> json, {
    bool strict = false,
  }) {
    final tasks = splitDeleted(json['tasks'], strict: strict);
    final mustDo = splitDeleted(json['mustDoCategories'], strict: strict);
    final wantToDo = splitDeleted(json['wantToDoCategories'], strict: strict);
    final settings = json['settings'];
    final bool share;
    final SyncMeta settingsMeta;
    if (settings is Map<String, dynamic>) {
      share = settings['shareCategories'] as bool? ?? false;
      settingsMeta = SyncMeta.fromJson(
        settings,
        knownKeys: const <String>{'shareCategories'},
      );
    } else {
      // v1 payload: the flag lived at the top level and carried no meta.
      share = json['shareCategories'] as bool? ?? false;
      settingsMeta = SyncMeta.migratedDefault;
    }
    return TaskMasterStateData(
      tasks: parseLive(tasks.live, TaskMaster.fromJson, strict: strict),
      mustDoCategories: parseLive(
        mustDo.live,
        TaskCategory.fromJson,
        strict: strict,
      ),
      wantToDoCategories: parseLive(
        wantToDo.live,
        TaskCategory.fromJson,
        strict: strict,
      ),
      shareCategories: share,
      settingsMeta: settingsMeta,
      deletedTasks: tasks.tombstones,
      deletedMustDoCategories: mustDo.tombstones,
      deletedWantToDoCategories: wantToDo.tombstones,
    );
  }

  /// Decodes persisted state, falling back to the default state when the stored
  /// payload is not valid JSON or is not a JSON object.
  factory TaskMasterStateData.decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        return TaskMasterStateData.initial();
      }
      return TaskMasterStateData.fromJson(decoded);
    } on FormatException {
      return TaskMasterStateData.initial();
    }
  }
}
