import 'dart:convert';

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
  const TaskCategory({required this.id, required this.name});

  final String id;
  final String name;

  TaskCategory copyWith({String? id, String? name}) {
    return TaskCategory(id: id ?? this.id, name: name ?? this.name);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name};

  factory TaskCategory.fromJson(Map<String, dynamic> json) {
    return TaskCategory(id: json['id'] as String, name: json['name'] as String);
  }
}

class TaskMaster {
  const TaskMaster({
    required this.id,
    required this.title,
    required this.kind,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.memo = '',
    this.categoryId,
    this.estimatedMinutes = 0,
  });

  final String id;
  final String title;
  final TaskKind kind;
  final int priority;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String memo;
  final String? categoryId;
  final int estimatedMinutes;

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
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'kind': kind.storageKey,
    'priority': priority,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'memo': memo,
    'categoryId': categoryId,
    'estimatedMinutes': estimatedMinutes,
  };

  factory TaskMaster.fromJson(Map<String, dynamic> json) {
    return TaskMaster(
      id: json['id'] as String,
      title: json['title'] as String,
      kind: TaskKindX.fromStorageKey(json['kind'] as String),
      priority: json['priority'] as int? ?? 3,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      memo: json['memo'] as String? ?? '',
      categoryId: json['categoryId'] as String?,
      estimatedMinutes: json['estimatedMinutes'] as int? ?? 0,
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
  const TaskMasterStateData({
    required this.tasks,
    required this.mustDoCategories,
    required this.wantToDoCategories,
    required this.shareCategories,
  });

  final List<TaskMaster> tasks;
  final List<TaskCategory> mustDoCategories;
  final List<TaskCategory> wantToDoCategories;
  final bool shareCategories;

  factory TaskMasterStateData.initial() {
    return TaskMasterStateData(
      tasks: const <TaskMaster>[],
      mustDoCategories: const <TaskCategory>[
        TaskCategory(id: 'must-work', name: '仕事'),
        TaskCategory(id: 'must-housework', name: '家事'),
        TaskCategory(id: 'must-admin', name: '雑務'),
      ],
      wantToDoCategories: const <TaskCategory>[
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
  }) {
    return TaskMasterStateData(
      tasks: tasks ?? this.tasks,
      mustDoCategories: mustDoCategories ?? this.mustDoCategories,
      wantToDoCategories: wantToDoCategories ?? this.wantToDoCategories,
      shareCategories: shareCategories ?? this.shareCategories,
    );
  }

  List<TaskCategory> categoriesFor(TaskKind kind) {
    return kind == TaskKind.mustDo ? mustDoCategories : wantToDoCategories;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tasks': tasks.map((task) => task.toJson()).toList(),
    'mustDoCategories': mustDoCategories
        .map((category) => category.toJson())
        .toList(),
    'wantToDoCategories': wantToDoCategories
        .map((category) => category.toJson())
        .toList(),
    'shareCategories': shareCategories,
  };

  String encode() => jsonEncode(toJson());

  factory TaskMasterStateData.fromJson(Map<String, dynamic> json) {
    return TaskMasterStateData(
      tasks: (json['tasks'] as List<dynamic>? ?? <dynamic>[])
          .map(
            (dynamic item) => TaskMaster.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      mustDoCategories:
          (json['mustDoCategories'] as List<dynamic>? ?? <dynamic>[])
              .map(
                (dynamic item) =>
                    TaskCategory.fromJson(item as Map<String, dynamic>),
              )
              .toList(),
      wantToDoCategories:
          (json['wantToDoCategories'] as List<dynamic>? ?? <dynamic>[])
              .map(
                (dynamic item) =>
                    TaskCategory.fromJson(item as Map<String, dynamic>),
              )
              .toList(),
      shareCategories: json['shareCategories'] as bool? ?? false,
    );
  }

  factory TaskMasterStateData.decode(String source) {
    return TaskMasterStateData.fromJson(
      jsonDecode(source) as Map<String, dynamic>,
    );
  }
}
