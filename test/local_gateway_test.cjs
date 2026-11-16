'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {start, startLocalGateway} = require('../lib/agent_runtime/execution/provider_relay.cjs');
test('local transport is explicit, fixed and requires trusted admission', () => {
  const config = {origin: 'http://127.0.0.1:20128', approvedOrigins: ['http://127.0.0.1:20128'],
    model: 'cx/gpt-6-luna-low', timeoutMs: 1000, inference: {max_completion_tokens: 128,
      stream: true, stream_options: {include_usage: true}},
    identity: {run_id: 'r', architecture: 'a', step_id: 's', attempt: 't'}};
  assert.throws(() => start(config, () => {}), /provider_relay_configuration_invalid/);
  assert.throws(() => startLocalGateway(config, () => {}), /local_gateway_configuration_invalid/);
  for (const origin of ['http://localhost:20128', 'http://127.0.0.1:20129',
    'http://example.com', 'https://127.0.0.1:20128']) {
    assert.throws(() => startLocalGateway({...config, origin}, () => {}, () => {}),
      /local_gateway_configuration_invalid/);
  }
  assert.throws(() => startLocalGateway({...config, model: 'fallback'}, () => {}, () => {}),
    /provider_relay_configuration_invalid/);
});

test('local relay audits bounded inference rejection reasons without forwarding or exposing values', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-policy-'));
  const credentialFile = path.join(dir, 'credential');
  fs.writeFileSync(credentialFile, 'credential-secret');
  const records = [];
  let admissions = 0;
  const inference = {max_completion_tokens: 128, stream: true, stream_options: {include_usage: true}};
  const relay = startLocalGateway({origin: 'http://127.0.0.1:20128',
    approvedOrigins: ['http://127.0.0.1:20128'], model: 'cx/gpt-6-luna-low',
    timeoutMs: 1000, credentialFile, socketPath: path.join(dir, 'relay.sock'),
    allowTools: true, inference,
    identity: {run_id: 'r', architecture: 'a', step_id: 's', attempt: 't'}},
  record => records.push(record), () => { admissions++; });
  try {
    await new Promise(resolve => relay.listen(path.join(dir, 'relay.sock'), resolve));
    const base = {model: 'cx/gpt-6-luna-low', messages: [{role: 'user', content: 'private-message'}], ...inference};
    const tool = {type: 'function', function: {name: 'safe', parameters: {type: 'object'}}};
    const cases = [
      [{...base, extra: 'private-value'}, 'unknown_fields'],
      [{...base, tools: [{type: 'private-value'}]}, 'tools'],
      [{...base, tools: [tool], tool_choice: 'private-value'}, 'tool_choice'],
      [{...base, tool_choice: 'auto'}, 'tool_choice'],
      [{...base, tool_choice: 'none'}, 'tool_choice'],
      [{...base, tools: [tool], tool_choice: 'required'}, 'tool_choice'],
      [{...base, tools: [tool], tool_choice: {type: 'function', function: {name: 'safe'}}}, 'tool_choice'],
      [{...base, messages: [{role: 'private-value'}]}, 'messages'],
      [{...base, max_completion_tokens: 129}, 'required_contract'],
      [{...base, stream: false}, 'required_contract'],
      [{...base, model: 'private-value'}, 'required_contract'],
      [null, 'required_contract']
    ];
    for (const [body, reason] of cases) {
      const response = await new Promise((resolve, reject) => {
        const req = http.request({socketPath: path.join(dir, 'relay.sock'),
          path: '/v1/chat/completions', method: 'POST'}, res => {
          let text = '';
          res.on('data', chunk => { text += chunk; });
          res.on('end', () => resolve({status: res.statusCode, text}));
        });
        req.on('error', reject);
        req.end(JSON.stringify(body));
      });
      assert.equal(response.status, 403);
      assert.equal(response.text, '');
      const record = records.at(-1);
      assert.equal(record.inference_policy_reason, reason);
      assert.equal(record.error, 'inference_policy');
      assert.equal(record.upstream_attempted, false);
      assert.doesNotMatch(JSON.stringify(record), /private-value|private-message|credential-secret/);
    }
    assert.equal(admissions, 0);
  } finally {
    await new Promise(resolve => relay.close(resolve));
    fs.rmSync(dir, {recursive: true, force: true});
  }
});
