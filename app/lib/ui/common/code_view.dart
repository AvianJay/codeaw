import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

final Highlight _highlight = Highlight()..registerLanguages(builtinAllLanguages);

const _extToLang = <String, String>{
  'ts': 'typescript', 'tsx': 'typescript', 'js': 'javascript', 'jsx': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
  'dart': 'dart', 'py': 'python', 'rs': 'rust', 'go': 'go', 'java': 'java', 'kt': 'kotlin', 'kts': 'kotlin', 'swift': 'swift',
  'c': 'c', 'h': 'c', 'cc': 'cpp', 'cpp': 'cpp', 'hpp': 'cpp', 'cs': 'csharp', 'rb': 'ruby', 'php': 'php', 'lua': 'lua',
  'sh': 'bash', 'bash': 'bash', 'zsh': 'bash', 'ps1': 'powershell', 'psm1': 'powershell', 'bat': 'dos', 'cmd': 'dos',
  'json': 'json', 'yaml': 'yaml', 'yml': 'yaml', 'toml': 'ini', 'ini': 'ini', 'xml': 'xml', 'html': 'xml', 'svg': 'xml',
  'css': 'css', 'scss': 'scss', 'less': 'less', 'md': 'markdown', 'sql': 'sql', 'gradle': 'gradle', 'dockerfile': 'dockerfile',
  'vue': 'xml', 'diff': 'diff', 'patch': 'diff',
};

const _aliases = <String, String>{
  'ts': 'typescript', 'js': 'javascript', 'py': 'python', 'sh': 'bash', 'shell': 'bash', 'console': 'bash', 'zsh': 'bash',
  'yml': 'yaml', 'html': 'xml', 'rs': 'rust', 'kt': 'kotlin', 'c++': 'cpp', 'cs': 'csharp', 'ps': 'powershell', 'ps1': 'powershell',
  'jsonc': 'json', 'tsx': 'typescript', 'jsx': 'javascript', 'text': '', 'txt': '', 'plaintext': '',
};

String? languageForPath(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (name == 'dockerfile') return 'dockerfile';
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return _extToLang[name.substring(dot + 1)];
}

String? normalizeLanguage(String? lang) {
  if (lang == null) return null;
  final l = lang.trim().toLowerCase();
  if (l.isEmpty) return null;
  final mapped = _aliases[l] ?? l;
  if (mapped.isEmpty) return null;
  return builtinAllLanguages.containsKey(mapped) ? mapped : null;
}

/// Syntax-highlighted spans; falls back to plain text for unknown languages or huge inputs.
TextSpan highlightSpan(String code, String? language, TextStyle base, Brightness brightness) {
  final lang = normalizeLanguage(language);
  if (lang == null || code.length > 200000) return TextSpan(text: code, style: base);
  try {
    final result = _highlight.highlight(code: code, language: lang);
    final renderer = TextSpanRenderer(base, brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme);
    result.render(renderer);
    return renderer.span ?? TextSpan(text: code, style: base);
  } catch (_) {
    return TextSpan(text: code, style: base);
  }
}

TextStyle monoStyle(BuildContext context, {double size = 12.5, Color? color}) => TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Roboto Mono', 'Noto Sans Mono', 'Courier'],
      fontSize: size,
      height: 1.35,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );

/// A code block: language label, copy button, horizontal scroll, optional line numbers.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language, this.lineNumbers = false, this.maxHeight, this.wrap = false, this.highlight = true});

  final String code;
  final String? language;
  final bool lineNumbers;
  final double? maxHeight;
  final bool wrap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = monoStyle(context);
    final span = highlight ? highlightSpan(code, language, base, Theme.of(context).brightness) : TextSpan(text: code, style: base);
    Widget text = SelectableText.rich(span, style: base);
    if (lineNumbers) {
      final count = '\n'.allMatches(code).length + 1;
      text = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(List.generate(count, (i) => '${i + 1}').join('\n'), style: base.copyWith(color: scheme.outline), textAlign: TextAlign.right),
          const SizedBox(width: 12),
          if (wrap) Expanded(child: text) else text,
        ],
      );
    }
    Widget body = wrap
        ? Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: text)
        : SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: text);
    if (maxHeight != null) {
      body = ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight!), child: SingleChildScrollView(child: body));
    }
    return Container(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row: language label + copy, above the code so it never covers it.
          SizedBox(
            height: 28,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(child: Text(language ?? '', style: TextStyle(fontSize: 11, color: scheme.outline))),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已複製'), duration: Duration(seconds: 1)));
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Icon(Icons.copy_rounded, size: 15, color: scheme.outline),
                  ),
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}
