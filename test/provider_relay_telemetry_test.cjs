'use strict';
// Synthetic protocol fixtures only: these are not installed-provider evidence.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const {execFileSync} = require('node:child_process');
const {start} = require('../lib/agent_runtime/execution/provider_relay.cjs');

test('response model is reported identity, not requested route or served attestation', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-telemetry-'));
  const key = path.join(root, 'key.pem'), cert = path.join(root, 'cert.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
    '-out', cert, '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'], {stdio: 'ignore'});
  const credentialFile = path.join(root, 'credential');
  fs.writeFileSync(credentialFile, 'fixture-secret-never-log');
  const usage = {prompt_tokens: 11, completion_tokens: 7, total_tokens: 18,
    prompt_tokens_details: {cached_tokens: 3}, completion_tokens_details: {reasoning_tokens: 2}};
  const fixtures = [
    {model: 'gpt-6.1', usage},
    {model: 'gpt-6.1'},
    {usage},
    {model: 'gpt-6.1', usage: {prompt_tokens: 12, private_text: 'must-not-log',
      completion_tokens_details: {reasoning_tokens: 4, secret: 'must-not-log'}}},
    {model: 'gpt-6.1', usage, interim: true}
  ];
  let index = 0;
  const provider = https.createServer({key: fs.readFileSync(key), cert: fs.readFileSync(cert)}, (req, res) => {
    req.resume();
    req.on('end', () => {
      res.writeHead(200, {'content-type': 'text/event-stream'});
      const fixture = fixtures[index++];
      const interim = fixture.interim ? 'data: {"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}\n\n' : '';
      res.end(`${interim}data: ${JSON.stringify(fixture)}\n\ndata: [DONE]\n\n`);
    });
  });
  await new Promise(resolve => provider.listen(0, 'localhost', resolve));
  const origin = `https://localhost:${provider.address().port}`;
  const records = [];
  const inference = {max_completion_tokens: 32000, stream: true, stream_options: {include_usage: true}};
  const relay = start({origin, approvedOrigins: [origin], caFile: cert, credentialFile,
    model: 'cx/gpt-6-luna-low', route: 'OmniRoute', inference, timeoutMs: 2000,
    identity: {run_id: 'trusted-run', architecture: 'telemetry', step_id: 'probe', attempt: 'trusted-attempt'}}, record => records.push(record));
  const socketPath = path.join(root, 'relay.sock');
  await new Promise(resolve => relay.listen(socketPath, resolve));
  try {
    for (const fixture of fixtures) {
      const body = JSON.stringify({model: 'cx/gpt-6-luna-low', ...inference,
        messages: [{role: 'user', content: 'private-prompt-never-log'}]});
      await new Promise((resolve, reject) => {
        const req = http.request({socketPath, path: '/v1/chat/completions', method: 'POST'}, res => {
          res.resume(); res.on('end', resolve);
        });
        req.on('error', reject); req.end(body);
      });
      const record = records.at(-1);
      assert.equal(record.requested_model, 'cx/gpt-6-luna-low');
      assert.equal(record.upstream_attempted, true);
      assert.equal(record.upstream_response_status, 200);
      assert.equal(record.stream_diagnostic.streaming, true);
      assert.equal(record.stream_diagnostic.seen_done, true);
      assert.equal(record.stream_diagnostic.finish_seen, false);
      assert.equal(record.stream_diagnostic.stream_ended, true);
      assert.equal(record.provider_route, 'OmniRoute');
      assert.equal(record.response_model, fixture.model || null);
      assert.equal(record.served_model, null);
      assert.equal(record.run_id, 'trusted-run');
      assert.deepEqual(record.usage, fixture.usage?.total_tokens !== undefined ? fixture.usage : null);
      assert.equal(record.accounting_complete, false);
      assert.ok(record.accounting_issues.includes('served_identity_unattested'));
    }
    assert.ok(!JSON.stringify(records).includes('fixture-secret-never-log'));
    assert.ok(!JSON.stringify(records).includes('private-prompt-never-log'));
    assert.ok(records[1].accounting_issues.includes('usage_not_reported'));
    assert.ok(records[3].accounting_issues.includes('usage_invalid_or_conflicting'));
    assert.equal(records[3].usage, null);
    assert.equal(records[3].observed_usage.prompt_tokens, 12);
    assert.equal(records[3].observed_usage.completion_tokens, null);
    assert.equal(records[3].observed_usage.total_tokens, null);
    assert.equal(records[3].observed_usage.completion_tokens_details.reasoning_tokens, 4);
    assert.equal(records[1].observed_usage, null);
    assert.ok(!JSON.stringify(records).includes('must-not-log'));
    assert.deepEqual(records[3].stream_diagnostic.malformed_reasons, ['usage_invalid_counts']);
    assert.deepEqual(records[4].stream_diagnostic.malformed_reasons, []);
    assert.equal(records[4].stream_diagnostic.usage_observation_count, 2);
    assert.deepEqual(records[4].stream_diagnostic.usage_totals_distinct, [0, 18]);
    assert.equal(records[4].error, null);
    assert.equal(records[4].usage_reporting_semantics, 'cumulative_observed');
  } finally {
    await new Promise(resolve => relay.close(resolve));
    await new Promise(resolve => provider.close(resolve));
    for (const name of ['key.pem', 'cert.pem', 'credential']) fs.unlinkSync(path.join(root, name));
    fs.rmdirSync(root);
  }
});
