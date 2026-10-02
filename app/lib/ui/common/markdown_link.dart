import 'markdown_image.dart';

/// Resolve a file link on the bridge, including common source-line suffixes.
({String path, int? line})? markdownFileLink(
  String source, {
  String? basePath,
}) {
  source = source.trim();
  if (source.startsWith('<') && source.endsWith('>')) {
    source = source.substring(1, source.length - 1);
  }
  if (source.isEmpty || source.startsWith('#') || source.contains('?')) {
    return null;
  }
  int? line;
  final fragment = source.indexOf('#');
  if (fragment >= 0) {
    final match = RegExp(
      r'^L([1-9]\d*)(?:C[1-9]\d*)?(?:-L?[1-9]\d*(?:C[1-9]\d*)?)?$',
    ).firstMatch(source.substring(fragment + 1));
    if (match != null) line = int.tryParse(match.group(1)!);
    source = source.substring(0, fragment);
  }
  final suffix = RegExp(r':([1-9]\d*)(?::[1-9]\d*)?$').firstMatch(source);
  if (suffix != null) {
    line ??= int.tryParse(suffix.group(1)!);
    source = source.substring(0, suffix.start);
  }
  try {
    final path = markdownImagePath(source, basePath: basePath);
    return path == null || path.isEmpty ? null : (path: path, line: line);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  } on UnsupportedError {
    return null;
  }
}
