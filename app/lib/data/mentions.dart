/// `@` file mentions: typed as `@relative/path`, sent as ACP `resource_link` blocks.
library;

bool isWindowsPath(String path) => RegExp(r'^[a-zA-Z]:[\\/]|^\\\\').hasMatch(path);

/// A `file:` URI in the bridge's path conventions, not the phone's.
String fileUriOf(String path) => Uri.file(path, windows: isWindowsPath(path)).toString();

/// A file or folder offered after `@`.
class FileSuggestion {
  const FileSuggestion({required this.path, required this.relative, this.directory = false});

  factory FileSuggestion.fromJson(Map<dynamic, dynamic> json) => FileSuggestion(
        path: '${json['path']}',
        relative: '${json['relative'] ?? json['path']}',
        directory: json['type'] == 'dir',
      );

  /// Absolute path on the bridge.
  final String path;

  /// Relative to the session folder, with `/` separators.
  final String relative;
  final bool directory;

  /// The text written after `@`; folders keep a trailing slash.
  String get token => directory ? '$relative/' : relative;

  String get name {
    final parts = relative.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? relative : parts.last;
  }
}

/// Whether an `@` at [index] can start a mention: not inside an e-mail address
/// or word, but CJK text may run straight into it.
bool mentionCanStartAt(String text, int index) => index == 0 || !RegExp(r'[\w.+\-@]').hasMatch(text[index - 1]);

/// Where each known `@token` appears. A mention ends at the end of the text,
/// whitespace or punctuation; the longest known token wins.
List<({int start, int end, String token})> mentionRanges(String text, Iterable<String> tokens) {
  final known = tokens.where((t) => t.isNotEmpty).toList()..sort((a, b) => b.length.compareTo(a.length));
  final ranges = <({int start, int end, String token})>[];
  if (known.isEmpty) return ranges;
  final pathChar = RegExp(r'[\w\-/\\]');
  var i = text.indexOf('@');
  while (i >= 0) {
    if (mentionCanStartAt(text, i)) {
      for (final token in known) {
        final end = i + 1 + token.length;
        if (!text.startsWith(token, i + 1) || (end < text.length && pathChar.hasMatch(text[end]))) continue;
        ranges.add((start: i, end: end, token: token));
        i = end - 1;
        break;
      }
    }
    i = text.indexOf('@', i + 1);
  }
  return ranges;
}

/// Prompt blocks for [text], with each known mention as a `resource_link` in place.
List<Map<String, dynamic>> promptBlocks(String text, Map<String, String> mentions) {
  final blocks = <Map<String, dynamic>>[];
  var at = 0;
  for (final r in mentionRanges(text, mentions.keys)) {
    if (r.start > at) blocks.add({'type': 'text', 'text': text.substring(at, r.start)});
    blocks.add({'type': 'resource_link', 'name': r.token, 'uri': mentions[r.token]});
    at = r.end;
  }
  if (at < text.length) blocks.add({'type': 'text', 'text': text.substring(at)});
  return blocks;
}
