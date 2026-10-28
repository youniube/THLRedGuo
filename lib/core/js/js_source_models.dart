class JsSourceMeta {
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String type;
  final String icon;
  final bool requiresAuth;
  final List<String> features;
  final String fileName;
  final String sourceUrl;

  const JsSourceMeta({
    required this.id,
    required this.name,
    this.version = '1.0.0',
    this.description = '',
    this.author = '',
    this.type = 'video',
    this.icon = '',
    this.requiresAuth = false,
    this.features = const [],
    this.fileName = '',
    this.sourceUrl = '',
  });

  factory JsSourceMeta.fromJson(Map<String, dynamic> json) {
    return JsSourceMeta(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '1.0.0',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? '',
      type: json['type'] as String? ?? 'video',
      icon: json['icon'] as String? ?? '',
      requiresAuth: json['requiresAuth'] as bool? ?? false,
      fileName: json['fileName'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      features:
          (json['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'author': author,
    'type': type,
    'icon': icon,
    'requiresAuth': requiresAuth,
    'features': features,
    'fileName': fileName,
    'sourceUrl': sourceUrl,
  };

  JsSourceMeta withImport({
    required String fileName,
    required String sourceUrl,
  }) => JsSourceMeta(
    id: id,
    name: name,
    version: version,
    description: description,
    author: author,
    type: type,
    icon: icon,
    requiresAuth: requiresAuth,
    features: features,
    fileName: fileName,
    sourceUrl: sourceUrl,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JsSourceMeta &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class JsSourceUpdateResult {
  const JsSourceUpdateResult({
    required this.sourceId,
    required this.name,
    required this.success,
    this.changed = false,
    this.added = false,
    this.error = '',
  });

  final String sourceId, name, error;
  final bool success, changed, added;

  factory JsSourceUpdateResult.fromJson(Map<String, dynamic> json) =>
      JsSourceUpdateResult(
        sourceId: json['sourceId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        success: json['success'] == true,
        changed: json['changed'] == true,
        added: json['added'] == true,
        error: json['error'] as String? ?? '',
      );
}
