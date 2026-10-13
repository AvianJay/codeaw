/// Model families that change how the app presents a session, independent of
/// which agent runs the model.
enum ModelFamily { openai, claude, gemini, grok }

// Whole-word matches, so names such as `llama-gptq` or `groking` stay unknown.
final _patterns = [
  (ModelFamily.openai, RegExp(r'(?:^|[^a-z0-9])(?:(?:chat)?gpt(?![a-z])|codex(?![a-z])|o[1-9](?![a-z0-9]))')),
  (ModelFamily.claude, RegExp(r'(?:^|[^a-z0-9])claude(?![a-z])')),
  (ModelFamily.gemini, RegExp(r'(?:^|[^a-z0-9])gemini(?![a-z])')),
  (ModelFamily.grok, RegExp(r'(?:^|[^a-z0-9])grok(?![a-z])')),
];

/// The family named earliest in [name], or null when none is.
ModelFamily? _familyIn(String name) {
  final lower = name.toLowerCase();
  ModelFamily? found;
  var at = lower.length + 1;
  for (final (family, pattern) in _patterns) {
    final match = pattern.firstMatch(lower);
    if (match != null && match.start < at) {
      found = family;
      at = match.start;
    }
  }
  return found;
}

/// Family of a selected model. The explicit [value] decides; the display
/// [label] only helps when the value is an opaque id such as `default`.
ModelFamily? modelFamilyOf(String? value, {String? label}) =>
    (value == null ? null : _familyIn(value)) ??
    (label == null ? null : _familyIn(label));

/// Whether thoughts arrive as Markdown summaries (Codex or any GPT model) and
/// are folded into the turn's thought summary instead of shown inline.
bool thoughtSummaryFor(String agentId, ModelFamily? model) =>
    agentId == 'codex' || model == ModelFamily.openai;
