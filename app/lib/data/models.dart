/// Thin, tolerant views over the JSON the bridge sends. Unknown fields are ignored.
library;

class AgentInfo {
  AgentInfo({required this.id, required this.name, required this.status, this.error, this.steering = false, this.image = false, this.version});

  final String id;
  final String name;
  final String status;
  final String? error;
  final bool steering;
  final bool image;
  final String? version;

  factory AgentInfo.fromJson(Map<String, dynamic> j) {
    final caps = j['capabilities'] as Map<String, dynamic>?;
    final prompt = caps?['promptCapabilities'] as Map<String, dynamic>?;
    final info = j['agentInfo'] as Map<String, dynamic>?;
    return AgentInfo(
      id: j['id'] as String,
      name: j['name'] as String? ?? j['id'] as String,
      status: j['status'] as String? ?? 'stopped',
      error: j['error'] as String?,
      steering: j['steering'] == true,
      image: prompt?['image'] == true,
      version: info?['version'] as String?,
    );
  }
}

class SessionSummary {
  SessionSummary({
    required this.id,
    required this.agentId,
    required this.cwd,
    this.title,
    this.updatedAt,
    this.state = 'idle',
    this.pending = 0,
    this.queued = 0,
    this.known = false,
  });

  final String id;
  final String agentId;
  final String cwd;
  String? title;
  DateTime? updatedAt;
  String state;
  int pending;
  int queued;
  bool known;

  factory SessionSummary.fromJson(Map<String, dynamic> j) {
    final m = (j['_meta'] as Map?)?['codeaw'] as Map? ?? const {};
    final id = j['sessionId'] as String;
    return SessionSummary(
      id: id,
      agentId: m['agentId'] as String? ?? id.split(':').first,
      cwd: j['cwd'] as String? ?? '',
      title: j['title'] as String?,
      updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      state: m['state'] as String? ?? 'idle',
      pending: (m['pending'] as num?)?.toInt() ?? 0,
      queued: (m['queued'] as num?)?.toInt() ?? 0,
      known: m['known'] == true,
    );
  }

  String get displayTitle => (title?.trim().isNotEmpty ?? false) ? title!.trim() : folderName(cwd);
}

String folderName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

class ConfigValue {
  ConfigValue(this.value, this.name, this.description, this.group);
  final String value;
  final String name;
  final String? description;
  final String? group;
}

/// A session config option (`select` or `boolean`), see ACP "Session Config Options".
class ConfigOption {
  ConfigOption(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? id;
  String? get description => json['description'] as String?;
  String? get category => json['category'] as String?;
  String get type => json['type'] as String? ?? 'select';
  Object? get currentValue => json['currentValue'];

  List<ConfigValue> get values {
    final out = <ConfigValue>[];
    for (final o in (json['options'] as List? ?? const [])) {
      if (o is! Map) continue;
      if (o['options'] is List) {
        for (final v in o['options'] as List) {
          if (v is Map) out.add(ConfigValue('${v['value']}', '${v['name'] ?? v['value']}', v['description'] as String?, o['name'] as String?));
        }
      } else {
        out.add(ConfigValue('${o['value']}', '${o['name'] ?? o['value']}', o['description'] as String?, null));
      }
    }
    return out;
  }

  String get currentLabel {
    if (type == 'boolean') return currentValue == true ? '開' : '關';
    for (final v in values) {
      if (v.value == currentValue) return v.name;
    }
    return '$currentValue';
  }
}

/// A file the bridge stored for an agent to read (`POST /api/uploads`).
class UploadedFile {
  const UploadedFile({required this.path, required this.uri, required this.name, required this.size, this.mimeType});

  factory UploadedFile.fromJson(Map<String, dynamic> j) => UploadedFile(
        path: '${j['path']}',
        uri: '${j['uri']}',
        name: '${j['name']}',
        size: (j['size'] as num?)?.toInt() ?? 0,
        mimeType: j['mimeType'] as String?,
      );

  final String path;
  final String uri;
  final String name;
  final int size;
  final String? mimeType;

  /// Agents read the file themselves, so any type works.
  Map<String, dynamic> get block => {'type': 'resource_link', 'name': name, 'uri': uri, 'size': size, 'mimeType': ?mimeType};
}

class UploadException implements Exception {
  const UploadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Plain text of an ACP content block, for previews and copy.
String blockText(Map<String, dynamic> block) {
  switch (block['type']) {
    case 'text':
      return block['text'] as String? ?? '';
    case 'resource':
      final r = block['resource'] as Map?;
      return r?['text'] as String? ?? r?['uri'] as String? ?? '';
    case 'resource_link':
      return block['name'] as String? ?? block['uri'] as String? ?? '';
    default:
      return '';
  }
}
