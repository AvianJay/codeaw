// Recorded AGY NDJSON shapes, with local deterministic turns for transport tests.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';

const args = process.argv.slice(2);
if (args.includes('models')) {
  console.log('gemini-3.8-flash-low\tGemini 3.8 Flash (Low)');
  process.exit(0);
}
const arg = (name) => args[args.indexOf(name) + 1];
if (arg('--model') === 'invalid-model') {
  console.log(JSON.stringify({ event: 'result', result: { status: 'ERROR', error: 'Unknown model invalid-model' } }));
  process.exit(1);
}
const nativeId = args.includes('--conversation') ? arg('--conversation') : randomUUID();
const file = path.join(process.env.AGY_FIXTURE_HOME, nativeId + '.json');
let state = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { word: '', turns: 0 };
fs.appendFileSync(path.join(process.env.AGY_FIXTURE_HOME, 'launches.jsonl'), JSON.stringify({ nativeId, args, cwd: process.cwd(), endpoint: process.env.GOOGLE_GEMINI_BASE_URL }) + '\n');
const emit = (e) => process.stdout.write(JSON.stringify(e) + '\n');
emit({ event: 'init', conversation_id: nativeId, init: { cwd: process.cwd(), model: arg('--model'), permission_mode: 'request-review' } });

async function turn(line) {
  const event = JSON.parse(line);
  if (event.event !== 'user') throw new Error('Only user events are supported');
  const text = event.message.content;
  if (text === 'hang') return new Promise(() => {});
  if (text === 'bad-json') { process.stdout.write('{not JSON or protocol}\n'); return; }
  if (text === 'crash') process.exit(7);
  if (text === 'error') {
    emit({ event: 'result', result: { status: 'ERROR', error: 'Invalid API key ' + process.env.GEMINI_API_KEY } });
    return;
  }
  if (text.startsWith('remember ')) state.word = text.slice(9);
  let response = text === 'recall' ? state.word : text === 'settings' ? `${arg('--model')}|${args.includes('--effort') ? arg('--effort') : 'default'}|${arg('--mode')}` : text;
  if (text === 'tools') {
    const step = { conversation_id: nativeId, step_index: state.turns * 10 + 4, step_type: 'tool', tool_name: 'run_command' };
    emit({ event: 'step_update', step_update: { ...step, state: 'ACTIVE', tool_info: { name: 'run_command', parameters: { CommandLine: 'echo hello_headless_demo' } } } });
    emit({ event: 'step_update', step_update: { ...step, state: 'DONE', tool_info: { name: 'run_command', parameters: { CommandLine: 'echo hello_headless_demo' }, output: 'hello_headless_demo\r\n' } } });
    response = '工具完成🙂';
  }
  emit({ event: 'step_update', step_update: { conversation_id: nativeId, step_index: state.turns * 10 + 2, state: 'ACTIVE', step_type: 'agent_response', text_delta: response } });
  await new Promise((resolve) => setTimeout(resolve, 200));
  emit({ event: 'step_update', step_update: { conversation_id: nativeId, step_index: state.turns * 10 + 2, state: 'DONE', step_type: 'agent_response', text_delta: '\n' } });
  state.turns++;
  fs.writeFileSync(file, JSON.stringify(state));
  emit({ event: 'result', result: { conversation_id: nativeId, status: 'SUCCESS', response: response + '\n', num_turns: state.turns,
    usage: { input_tokens: state.turns * 100, output_tokens: state.turns * 7, thinking_tokens: state.turns * 3, cache_read_tokens: 0, total_tokens: state.turns * 107 } } });
}
const lines = createInterface({ input: process.stdin });
let pending = Promise.resolve();
lines.on('line', (line) => { pending = pending.then(() => turn(line)); });
lines.once('close', () => { void pending.then(() => process.exit(0)); });
