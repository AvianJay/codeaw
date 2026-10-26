import readline from 'node:readline';

const methods = [
  { id: 'oauth-personal', name: 'Log in with Google', description: 'Use your Google account', _meta: { private: 'fixture-private-metadata' } },
  { id: 'gemini-api-key', name: 'Gemini API key' },
  { id: 'terminal-login', name: 'Terminal login', type: 'terminal', args: ['--login'], env: { FIXTURE_KEY: 'fixture-private-env' } },
];
let authenticated = process.env.ACP_AUTH_PREAUTH === '1';
let nextSession = 0;
const calls = [];
const result = (id, value) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result: value }) + '\n');
const error = (id, code, message, data) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message, data } }) + '\n');

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const { id, method, params } = JSON.parse(line);
  if (method === 'initialize') {
    result(id, { protocolVersion: 1, agentInfo: { name: 'auth-fixture', version: '1.0.0' },
      agentCapabilities: { sessionCapabilities: { list: {} } }, authMethods: methods });
  } else if (method === 'authenticate') {
    calls.push(params);
    process.stderr.write('fixture-private-auth-stderr\n');
    setTimeout(() => {
      if (params.methodId === process.env.ACP_AUTH_FAIL_METHOD) {
        error(id, -32603, 'fixture-private-auth-error', { details: 'fixture-private-provider-config' });
      } else {
        authenticated = true;
        result(id, {});
      }
    }, 30);
  } else if (method === 'session/new') {
    if (!authenticated) error(id, -32000, 'Authentication required', { details: 'No authentication method selected. fixture-private-path-and-provider-config' });
    else result(id, { sessionId: 'session-' + ++nextSession });
  } else if (method === 'session/list') {
    result(id, { sessions: [] });
  } else if (method === '_fixture/authCalls') {
    result(id, { calls });
  } else if (id !== undefined) {
    result(id, {});
  }
});
