import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/model_family.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/ui/chat/chat_header.dart';
import 'package:flutter_test/flutter_test.dart';

SessionController _controller(String agent) {
  final c = SessionController(
    BridgeClient(
      HostConfig(
        name: 'test',
        urls: ['ws://localhost:1'],
        token: 'test',
        deviceId: 'test',
        deviceName: 'test',
      ),
    ),
    '$agent:test',
  );
  addTearDown(() {
    c.dispose();
    c.client.dispose();
  });
  return c;
}

Map<String, dynamic> _model(
  String value, {
  String id = 'model',
  String? category = 'model',
  List<(String, String)> options = const [],
}) => {
  'id': id,
  'name': 'Model',
  'category': ?category,
  'type': 'select',
  'currentValue': value,
  'options': [
    for (final (option, name) in options) {'value': option, 'name': name},
  ],
};

void main() {
  test('recognises model families from whole names', () {
    for (final (name, family) in <(String, ModelFamily?)>[
      ('gpt-5.1-codex', ModelFamily.openai),
      ('openai/gpt-5', ModelFamily.openai),
      ('GPT-5.2 (high)', ModelFamily.openai),
      ('gpt4o', ModelFamily.openai),
      ('ChatGPT-4o-latest', ModelFamily.openai),
      ('codex-mini-latest', ModelFamily.openai),
      ('o3', ModelFamily.openai),
      ('openai/o4-mini', ModelFamily.openai),
      ('anthropic/claude-sonnet-4-5', ModelFamily.claude),
      ('Claude Opus 4.1', ModelFamily.claude),
      ('gemini-2.5-pro', ModelFamily.gemini),
      ('google/gemini-3-pro-preview', ModelFamily.gemini),
      ('x-ai/grok-code-fast-1', ModelFamily.grok),
      ('grok-4', ModelFamily.grok),
      // The earliest family in the name decides.
      ('gemini-2.5-pro (o3 router)', ModelFamily.gemini),
      // Unrelated substrings stay unknown.
      ('llama-2-7b-gptq', null),
      ('codestral-latest', null),
      ('claudette', null),
      ('grokking-7b', null),
      ('turbo3', null),
      ('deepseek-r1', null),
      ('qwen3-coder', null),
      ('default', null),
      ('', null),
    ]) {
      expect(modelFamilyOf(name), family, reason: name);
    }
    expect(modelFamilyOf(null), isNull);
  });

  test('the explicit model value wins over its label', () {
    expect(
      modelFamilyOf('claude-sonnet-4-5', label: 'GPT-5'),
      ModelFamily.claude,
    );
    expect(
      modelFamilyOf('default', label: 'GPT-5.2 Codex'),
      ModelFamily.openai,
    );
    expect(modelFamilyOf('default', label: 'Recommended'), isNull);
    expect(modelFamilyOf(null, label: 'Gemini 2.5 Pro'), ModelFamily.gemini);
  });

  test('agent quota mapping comes before the model fallback', () {
    expect(cpaProviderFor('claude', ModelFamily.openai), 'claude');
    expect(cpaProviderFor('codex', ModelFamily.claude), 'codex');
    expect(cpaProviderFor('omp', ModelFamily.openai), 'codex');
    expect(cpaProviderFor('omp', ModelFamily.claude), 'claude');
    expect(cpaProviderFor('other', ModelFamily.gemini), 'antigravity');
    expect(cpaProviderFor('other', ModelFamily.grok), 'grok');
    expect(cpaProviderFor('omp', null), isNull);
  });

  test('thought summaries follow Codex and GPT models only', () {
    expect(thoughtSummaryFor('codex', null), isTrue);
    expect(thoughtSummaryFor('codex', ModelFamily.claude), isTrue);
    expect(thoughtSummaryFor('omp', ModelFamily.openai), isTrue);
    expect(thoughtSummaryFor('claude', ModelFamily.openai), isTrue);
    expect(thoughtSummaryFor('omp', ModelFamily.claude), isFalse);
    expect(thoughtSummaryFor('claude', null), isFalse);
  });

  test('controller reads the model option and follows config updates', () {
    final c = _controller('omp');
    expect(c.modelOption, isNull);
    expect(c.modelFamily, isNull);
    expect(c.thoughtSummary, isFalse);

    // Opaque values fall back to the selected option's label.
    c.timeline.configOptions = [
      {
        'id': 'mode',
        'name': 'Mode',
        'type': 'select',
        'currentValue': 'gpt',
        'options': const [],
      },
      _model(
        'default',
        id: 'llm',
        options: [('default', 'GPT-5.2 Codex'), ('other', 'Claude Sonnet')],
      ),
    ];
    expect(c.modelOption?.id, 'llm');
    expect(c.modelFamily, ModelFamily.openai);
    expect(c.thoughtSummary, isTrue);

    var notified = 0;
    c.timeline.addListener(() => notified++);
    c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': 'config_option_update',
        'configOptions': [
          _model('anthropic/claude-sonnet-4-5', category: null),
        ],
      },
    });
    c.timeline.flush();
    expect(notified, 1);
    expect(c.modelFamily, ModelFamily.claude);
    expect(c.thoughtSummary, isFalse);

    c.timeline.configOptions = [_model('local-model')];
    expect(c.modelFamily, isNull);
    expect(c.thoughtSummary, isFalse);
    expect(_controller('codex').thoughtSummary, isTrue);
  });
}
