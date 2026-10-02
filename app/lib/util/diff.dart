enum DiffKind { context, add, remove, hunk, meta }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNo, this.newNo});
  final DiffKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

List<String> _lines(String? s) {
  if (s == null || s.isEmpty) return const [];
  final l = s.split('\n');
  if (l.last.isEmpty) l.removeLast();
  return l;
}

/// Line diff (Myers, O((N+M)·D)) rendered as unified hunks with [context] lines around changes.
List<DiffLine> lineDiff(String? oldText, String? newText, {int context = 3}) {
  final a = _lines(oldText);
  final b = _lines(newText);
  final ops = _myers(a, b);
  // ops: 0 = equal, 1 = add (from b), -1 = remove (from a)
  final all = <DiffLine>[];
  var i = 0, j = 0;
  for (final op in ops) {
    if (op == 0) {
      all.add(DiffLine(DiffKind.context, a[i], oldNo: i + 1, newNo: j + 1));
      i++;
      j++;
    } else if (op < 0) {
      all.add(DiffLine(DiffKind.remove, a[i], oldNo: i + 1));
      i++;
    } else {
      all.add(DiffLine(DiffKind.add, b[j], newNo: j + 1));
      j++;
    }
  }
  if (all.every((l) => l.kind == DiffKind.context)) return const [];
  // Keep only changes plus `context` lines around them, separated by hunk headers.
  final keep = List<bool>.filled(all.length, false);
  for (var k = 0; k < all.length; k++) {
    if (all[k].kind != DiffKind.context) {
      for (var c = k - context; c <= k + context; c++) {
        if (c >= 0 && c < all.length) keep[c] = true;
      }
    }
  }
  final out = <DiffLine>[];
  var k = 0;
  while (k < all.length) {
    if (!keep[k]) {
      k++;
      continue;
    }
    final start = k;
    while (k < all.length && keep[k]) {
      k++;
    }
    final chunk = all.sublist(start, k);
    final oldStart = chunk.firstWhere((l) => l.oldNo != null, orElse: () => const DiffLine(DiffKind.context, '', oldNo: 0)).oldNo!;
    final newStart = chunk.firstWhere((l) => l.newNo != null, orElse: () => const DiffLine(DiffKind.context, '', newNo: 0)).newNo!;
    final oldCount = chunk.where((l) => l.kind != DiffKind.add).length;
    final newCount = chunk.where((l) => l.kind != DiffKind.remove).length;
    out.add(DiffLine(DiffKind.hunk, '@@ -$oldStart,$oldCount +$newStart,$newCount @@'));
    out.addAll(chunk);
  }
  return out;
}

List<int> _myers(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final max = n + m;
  if (max == 0) return const [];
  final offset = max + 1;
  final v = List<int>.filled(2 * max + 3, 0);
  final trace = <List<int>>[];
  for (var d = 0; d <= max; d++) {
    trace.add(List<int>.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1];
      } else {
        x = v[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        return _backtrack(trace, a.length, b.length, offset, d);
      }
    }
  }
  return const [];
}

/// Walks the saved `v` rows backwards; `trace[d]` is the state before round `d`.
List<int> _backtrack(List<List<int>> trace, int n, int m, int offset, int dEnd) {
  final ops = <int>[];
  var x = n, y = m;
  for (var d = dEnd; d >= 0; d--) {
    final vPrev = trace[d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && vPrev[offset + k - 1] < vPrev[offset + k + 1])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = d == 0 ? 0 : vPrev[offset + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(0);
      x--;
      y--;
    }
    if (d > 0) {
      if (x == prevX) {
        ops.add(1);
        y--;
      } else {
        ops.add(-1);
        x--;
      }
    }
  }
  return ops.reversed.toList();
}

/// One file section of a `git diff` output.
class FileDiff {
  FileDiff(this.path);
  String path;
  final lines = <DiffLine>[];
  int get added => lines.where((l) => l.kind == DiffKind.add).length;
  int get removed => lines.where((l) => l.kind == DiffKind.remove).length;
}

final _hunkRe = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Parses unified diff text (as produced by `git diff`) into per-file line lists.
List<FileDiff> parseUnifiedDiff(String text) {
  final files = <FileDiff>[];
  FileDiff? cur;
  var oldNo = 0, newNo = 0;
  for (final raw in text.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith('diff --git ')) {
      final m = RegExp(r' b/(.+)$').firstMatch(line);
      cur = FileDiff(m?.group(1) ?? line.substring(11));
      files.add(cur);
      continue;
    }
    if (cur == null) {
      if (line.startsWith('--- ') || line.startsWith('@@')) {
        cur = FileDiff('');
        files.add(cur);
      } else {
        continue;
      }
    }
    if (line.startsWith('+++ ')) {
      final p = line.substring(4);
      if (p != '/dev/null') cur.path = p.startsWith('b/') ? p.substring(2) : p;
      continue;
    }
    if (line.startsWith('--- ') || line.startsWith('index ') || line.startsWith('new file') || line.startsWith('deleted file') ||
        line.startsWith('similarity') || line.startsWith('rename ') || line.startsWith('old mode') || line.startsWith('new mode')) {
      cur.lines.add(DiffLine(DiffKind.meta, line));
      continue;
    }
    final h = _hunkRe.firstMatch(line);
    if (h != null) {
      oldNo = int.parse(h.group(1)!);
      newNo = int.parse(h.group(2)!);
      cur.lines.add(DiffLine(DiffKind.hunk, line));
      continue;
    }
    if (line.startsWith('+')) {
      cur.lines.add(DiffLine(DiffKind.add, line.substring(1), newNo: newNo++));
    } else if (line.startsWith('-')) {
      cur.lines.add(DiffLine(DiffKind.remove, line.substring(1), oldNo: oldNo++));
    } else if (line.startsWith(' ')) {
      cur.lines.add(DiffLine(DiffKind.context, line.substring(1), oldNo: oldNo++, newNo: newNo++));
    } else if (line.startsWith(r'\')) {
      cur.lines.add(DiffLine(DiffKind.meta, line));
    }
  }
  return files;
}
