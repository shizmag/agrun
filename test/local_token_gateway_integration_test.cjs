'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {PassThrough} = require('node:stream');
const {execFileSync} = require('node:child_process');
const {admission} = require('../scripts/local_token_gateway.cjs');
const {startOfflineTransport} = require('../lib/agent_runtime/execution/provider_relay.cjs');

test('durable subprocess ledger halts on wrong-then-right streamed model', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-test-ledger-'));
  try {
    const config = path.join(root, 'config.json');
    fs.writeFileSync(config, JSON.stringify({cell_id: 'test-cell', attempt_id: 'test-attempt',
      ledger: {path: path.join(root, 'ledger.jsonl'), intent_digest: 'a'.repeat(64), total_tokens: 10000000}}));
    let snapshot;
    const audits = [];
    const gate = admission({requestLimit: 4, ledger(message) {
      snapshot = JSON.parse(execFileSync('mise', ['exec', '--', 'bundle', 'exec', 'ruby',
        path.resolve(__dirname, '../scripts/local_token_ledger.rb'), config],
      {input: JSON.stringify(message), encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 30000}));
    }, emit(record) { audits.push(record); }});
    gate.authorizeRequest(Buffer.from('{}'), {}, 'first');
    gate.audit({request_id: 'first', response_models: ['wrong-model', 'cx/gpt-6-luna-low'],
      response_model: 'cx/gpt-6-luna-low', usage: {prompt_tokens: 1, completion_tokens: 1}});
    assert.equal(audits[0].ledger_error, 'settlement_failed');
    snapshot = JSON.parse(execFileSync('mise', ['exec', '--', 'bundle', 'exec', 'ruby', '-r', path.resolve(__dirname, '../lib/agent_runtime/execution/token_budget_ledger.rb'), '-e', 'c=JSON.parse(File.read(ARGV[0])); puts JSON.generate(AgentRuntime::Execution::TokenBudgetLedger.new(**c.fetch("ledger").transform_keys(&:to_sym)).snapshot)', config], {encoding: 'utf8', timeout: 30000}));
    assert.equal(snapshot.halted, true);
    assert.equal(snapshot.request_count, 1);
    assert.throws(() => gate.authorizeRequest(Buffer.from('{}'), {}, 'second'));
    assert.throws(() => execFileSync('mise', ['exec', '--', 'bundle', 'exec', 'ruby',
      path.resolve(__dirname, '../scripts/local_token_ledger.rb'), config],
    {input: JSON.stringify({action: 'reserve', request_id: 'after-restart'}), encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'], timeout: 30000}), /halted/);
    assert.equal(snapshot.request_count, 1);
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
});

test('offline gateway accepts tool call and tool result across sequential requests', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-test-tools-'));
  const credentialFile = path.join(root, 'credential');
  fs.writeFileSync(credentialFile, 'offline-only');
  const received = [], events = [], audits = [];
  const gate = admission({requestLimit: 2, ledger: e => events.push(e), emit: e => audits.push(e)});
  const model = 'cx/gpt-6-luna-low';
  const server = startOfflineTransport({origin: 'https://offline.invalid', approvedOrigins: ['https://offline.invalid'],
    model, credentialFile, route: 'offline', timeoutMs: 2000, allowTools: true,
    inference: {max_completion_tokens: 32000, stream: true, stream_options: {include_usage: true}},
    identity: {run_id: 'test', architecture: 'test', step_id: 'tools', attempt: 'one'}}, gate.audit, gate.authorizeRequest,
  {request(url, options, callback) {
    const request = new PassThrough(); let body = '';
    request.on('data', data => { body += data; }); request.setTimeout = () => request;
    request.on('finish', () => {
      received.push(JSON.parse(body));
      const response = new PassThrough(); response.statusCode = 200; response.headers = {'content-type': 'text/event-stream'};
      callback(response);
      const delta = received.length === 1 ? {tool_calls: [{index: 0, id: 'call_1', type: 'function', function: {name: 'read_file', arguments: '{"path":"README.md"}'}}]} : {content: 'done'};
      response.end('data: ' + JSON.stringify({model, choices: [{index: 0, delta, finish_reason: received.length === 1 ? 'tool_calls' : 'stop'}], usage: {prompt_tokens: 2, completion_tokens: 1, total_tokens: 3}}) + '\n\ndata: [DONE]\n\n');
    }); return request;
  }});
  const socketPath = path.join(root, 'gateway.sock');
  await new Promise(resolve => server.listen(socketPath, resolve));
  const send = messages => new Promise((resolve, reject) => {
    const request = http.request({socketPath, method: 'POST', path: '/v1/chat/completions', headers: {'content-type': 'application/json'}}, response => {
      let body = ''; response.on('data', data => { body += data; }); response.on('end', () => resolve({status: response.statusCode, body}));
    }); request.on('error', reject);
    request.end(JSON.stringify({model, messages, tools: [{type: 'function', function: {name: 'read_file', parameters: {type: 'object', properties: {path: {type: 'string'}}}}}], max_completion_tokens: 32000, stream: true, stream_options: {include_usage: true}}));
  });
  try {
    const first = await send([{role: 'user', content: 'read README'}]);
    assert.equal(first.status, 200); assert.match(first.body, /tool_calls/);
    const second = await send([{role: 'assistant', content: null, tool_calls: [{id: 'call_1', type: 'function', function: {name: 'read_file', arguments: '{"path":"README.md"}'}}]}, {role: 'tool', tool_call_id: 'call_1', content: 'offline file'}]);
    assert.equal(second.status, 200); assert.match(second.body, /done/);
    assert.equal(received[1].messages[1].tool_call_id, 'call_1');
    assert.deepEqual(events.map(e => e.action), ['reserve', 'settle', 'reserve', 'settle']);
    assert.equal(audits.length, 2);
  } finally { await new Promise(resolve => server.close(resolve)); fs.rmSync(root, {recursive: true, force: true}); }
});
