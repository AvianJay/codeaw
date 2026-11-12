/// One run of plain text: ordinary, or a link to [url].
typedef LinkRun = ({String text, String? url});

final _links = RegExp(
  // [label](https://…) with one level of parentheses in the target, or a bare URL.
  r'\[([^\[\]\n]+)\]\(\s*<?(https?://[^\s()<>]+(?:\([^\s()<>]*\)[^\s()<>]*)*)>?(?:\s+"[^"\n]*")?\s*\)'
  r'''|https?://[^\s<>"'`，。、；：！？「」『』（）【】《》]+''',
  caseSensitive: false,
);

/// Splits text nobody wrote as Markdown — a prompt, a pasted log — into plain
/// runs and the web links in it, so a link can be opened without the text
/// being reformatted.
List<LinkRun> linkRuns(String text) {
  final runs = <LinkRun>[];
  var from = 0;
  void plain(int to) {
    if (to > from) runs.add((text: text.substring(from, to), url: null));
  }

  for (final match in _links.allMatches(text)) {
    if (match.group(2) case final target?) {
      plain(match.start);
      runs.add((text: match.group(1)!, url: target));
      from = match.end;
      continue;
    }
    var url = match.group(0)!;
    // Sentence punctuation after a URL is not part of it; a closing bracket is
    // only when the URL opened one, as in a Wikipedia title.
    while (url.isNotEmpty) {
      final last = url[url.length - 1];
      final open = switch (last) { ')' => '(', ']' => '[', '}' => '{', _ => null };
      if ('.,;:!?*_~\\'.contains(last) ||
          (open != null && open.allMatches(url).length < last.allMatches(url).length)) {
        url = url.substring(0, url.length - 1);
      } else {
        break;
      }
    }
    if (Uri.tryParse(url)?.host.isEmpty ?? true) continue;
    plain(match.start);
    runs.add((text: url, url: url));
    from = match.start + url.length;
  }
  plain(text.length);
  return runs;
}

/// A Markdown link target as written, without the `<…>` wrapper or a
/// `"title"` — neither is part of where the link goes.
String linkTarget(String source) {
  source = source.trim();
  final titled = RegExp(r'''^(<[^>]*>|\S+)\s+("[^"]*"|'[^']*'|\([^)]*\))$''').firstMatch(source);
  if (titled != null) source = titled.group(1)!;
  if (source.length > 1 && source.startsWith('<') && source.endsWith('>')) {
    source = source.substring(1, source.length - 1).trim();
  }
  return source;
}
