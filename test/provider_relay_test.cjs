'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {start} = require('../lib/agent_runtime/execution/provider_relay.cjs');
test('configuration fails closed and rejected requests are attributable without credentials', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-relay-'));
  const credentialFile = path.join(root, 'credential');
  fs.writeFileSync(credentialFile, 'synthetic-test-secret');
  const config = {origin: 'https://localhost:9443', approvedOrigins: ['https://localhost:9443'],
    model: 'cx/gpt-6-luna-low', route: 'OmniRoute', timeoutMs: 100,
    identity: {run_id: 'offline', architecture: 'transport-test', step_id: 'probe', attempt: 1},
    inference: {}, credentialFile};
  for (const origin of ['http://localhost:9443', 'https://evil.invalid', 'https://localhost:9443/other']) {
    assert.throws(() => start({...config, origin}, () => {}), /configuration_invalid/);
  }
  const records = [];
  const server = start(config, r => records.push(r));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const status = await new Promise((resolve, reject) => {
      const req = http.request({host: '127.0.0.1', port: server.address().port,
        path: '/v1/chat/completions', method: 'POST', headers: {'content-length': 17}}, res => {
        res.resume(); res.on('end', () => resolve(res.statusCode));
      });
      req.on('error', reject); req.end('{"model":"other"}');
    });
    assert.equal(status, 403);
    assert.equal(records.length, 1);
    assert.equal(records[0].run_id, 'offline');
    assert.equal(records[0].usage, null);
    assert.equal(records[0].served_model, null);
    assert.equal(records[0].accounting_complete, false);
    assert.equal(JSON.stringify(records).includes('synthetic-test-secret'), false);
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.unlinkSync(credentialFile); fs.rmdirSync(root);
  }
});
