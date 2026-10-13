import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const root = process.env.ACP_FIXTURE_ROOT;
fs.mkdirSync(root, { recursive: true });
fs.appendFileSync(path.join(root, 'launches.jsonl'), JSON.stringify({ pid: process.pid }) + '\n');
const keepAlive = setInterval(() => {}, 1000);
const input = readline.createInterface({ input: process.stdin });
let closing = false;
const respond = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
function close() {
  if (process.env.ACP_FIXTURE_NO_EXIT === '1') return;
  if (closing) return;
  closing = true;
  process.stdout.end();
  setTimeout(() => {
    fs.writeFileSync(path.join(root, 'cleaned-' + process.pid), 'finished');
    clearInterval(keepAlive);
    process.exit(0);
  }, Number(process.env.ACP_FIXTURE_EXIT_DELAY ?? 350));
}
input.on('line', (line) => {
  const message = JSON.parse(line);
  if (message.method === 'initialize') {
    if (process.env.ACP_FIXTURE_NO_INIT === '1') return;
    setTimeout(() => {
      if (!closing) respond(message.id, { protocolVersion: 1, agentInfo: { name: 'fixture', version: '1.0.0' }, agentCapabilities: { sessionCapabilities: { list: {} } } });
    }, Number(process.env.ACP_FIXTURE_INIT_DELAY ?? 0));
  } else if (message.method === '_fixture/close') {
    respond(message.id, {});
    setTimeout(close, 10);
  } else if (message.method === '_fixture/crash') {
    process.exit(7);
  } else if (message.method === 'session/list') {
    respond(message.id, { sessions: [] });
  }
});
input.on('close', close);
