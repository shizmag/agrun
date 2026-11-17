'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {startOfflineTransport} = require('../lib/agent_runtime/execution/provider_relay.cjs');
const {captureFactory} = require('../lib/agent_runtime/execution/trace_capture.cjs');
const inference = {max_completion_tokens: 100, stream: true, stream_options: {include_usage: true}};
const frame = value => `data: ${JSON.stringify(value)}\r\n\r\n`;
async function fixture(options, action) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'agru-trace-')));
  fs.chmodSync(root, 0o700);
  const credentialFile = path.join(root, 'credential'); fs.writeFileSync(credentialFile, 'NEVER_CAPTURE_HEADER_SECRET');
  const directory = path.join(root, 'captures'); fs.mkdirSync(directory, {mode: 0o700});
  let submitted;
  const provider = http.createServer((req, res) => {
    const parts = []; req.on('data', b => parts.push(b));
    req.on('end', () => { submitted = JSON.parse(Buffer.concat(parts)); action(res); });
  });
  await new Promise(resolve => provider.listen(0, '127.0.0.1', resolve));
  const records = [];
  const config = {origin: 'https://offline.invalid', approvedOrigins: ['https://offline.invalid'],
    model: 'cx/gpt-6-luna-low', route: 'test', timeoutMs: 1000, inference, credentialFile,
    identity: {run_id: 'run', architecture: 'test', step_id: 'step', attempt: 3, trace_id: 'trace'},
    ...(options.capture !== false ? {traceCapture: {directory, rawAuthorized: options.raw === true}} : {})};
  const relay = startOfflineTransport(config, r => records.push(r), null, {
    request(url, opts, cb) { return http.request(`http://127.0.0.1:${provider.address().port}/`, opts, cb); }
  });
  await new Promise(resolve => relay.listen(0, '127.0.0.1', resolve));
  try {
    const body = {model: config.model, messages: [{role: 'user', content: 'private prompt'}], ...inference};
    await new Promise((resolve, reject) => {
      const bytes = JSON.stringify(body);
      const req = http.request({host: '127.0.0.1', port: relay.address().port, path: '/v1/chat/completions', method: 'POST',
        headers: {'content-length': Buffer.byteLength(bytes), authorization: 'solver-header-secret'}}, res => {
        res.resume(); res.on('end', resolve); res.on('aborted', resolve); res.on('error', resolve);
      }); req.on('error', reject); req.end(bytes);
    });
    await new Promise(resolve => setImmediate(resolve));
    const envelopes = fs.readdirSync(directory).map(name => {
      const file = path.join(directory, name);
      assert.equal(fs.statSync(file).mode & 0o777, 0o600);
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    });
    return {records, envelopes, submitted};
  } finally {
    relay.cancelUpstream(); relay.closeAllConnections(); provider.closeAllConnections();
    await Promise.all([new Promise(resolve => relay.close(resolve)), new Promise(resolve => provider.close(resolve))]);
    fs.rmSync(root, {recursive: true, force: true});
  }
}
test('explicit capture binds effective request, ordered split SSE bytes, text/tool reconstruction and usage', async () => {
  const events = [
    {id: 'reply', model: 'observed', choices: [{index: 0, delta: {role: 'assistant', content: 'Привет '}}]},
    {choices: [{index: 0, delta: {content: 'world', tool_calls: [{index: 0, id: 'call', type: 'function', function: {name: 'read', arguments: '{"x":'}}]}}]},
    {choices: [{index: 0, delta: {tool_calls: [{index: 0, function: {arguments: '1}'}}]}, finish_reason: 'tool_calls'}]},
    {choices: [], usage: {prompt_tokens: 4, completion_tokens: 2, total_tokens: 6}}
  ];
  const wire = Buffer.from(events.map(frame).join('') + 'data: [DONE]\r\n\r\n');
  const result = await fixture({raw: true}, res => {
    res.writeHead(200, {'content-type': 'text/event-stream', 'x-private': 'response-header-secret'});
    // Split a UTF-8 code point and SSE line delimiter across socket writes.
    const split = wire.indexOf(Buffer.from('Привет')) + 1;
    res.write(wire.subarray(0, split)); setImmediate(() => res.end(wire.subarray(split)));
  });
  assert.equal(result.envelopes.length, 1);
  const envelope = result.envelopes[0], payload = envelope.payload;
  assert.equal(envelope.digest, crypto.createHash('sha256').update(envelope.payload_json).digest('hex'));
  assert.deepEqual(JSON.parse(envelope.payload_json), payload);
  assert.deepEqual(payload.request_body, result.submitted);
  assert.equal(payload.identity.attempt, 3); assert.equal(payload.identity.trace_id, 'trace');
  assert.equal(payload.request_id, result.records[0].request_id);
  assert.equal(result.records[0].trace_capture.digest, envelope.digest);
  assert.deepEqual(Buffer.concat(payload.response_chunks.map(c => Buffer.from(c.base64, 'base64'))), wire);
  assert.deepEqual(payload.events.map(e => e.value), events);
  assert.equal(payload.reconstructed_response.choices[0].message.content, 'Привет world');
  assert.equal(payload.reconstructed_response.choices[0].message.tool_calls[0].function.arguments, '{"x":1}');
  assert.deepEqual(payload.usage, {prompt_tokens: 4, completion_tokens: 2, total_tokens: 6});
  assert.equal(payload.complete, true); assert.equal(payload.interrupted, false); assert.ok(payload.ttft_ms >= 0);
  for (const secret of ['NEVER_CAPTURE_HEADER_SECRET', 'solver-header-secret', 'response-header-secret']) assert.ok(!JSON.stringify(result).includes(secret));
  assert.ok(!JSON.stringify(result.records).includes('private prompt'));
});
test('inherited environment cannot authorize raw capture', async () => {
  process.env.AGRU_TRACE_RAW = 'true';
  try {
    const result = await fixture({capture: false}, res => { res.writeHead(200, {'content-type': 'text/event-stream'}); res.end('data: [DONE]\n\n'); });
    assert.deepEqual(result.envelopes, []); assert.equal(result.records[0].trace_capture, undefined);
  } finally { delete process.env.AGRU_TRACE_RAW; }
});
test('interrupted response keeps partial bytes and fixed transport error', async () => {
  const result = await fixture({raw: true}, res => {
    res.writeHead(200, {'content-type': 'text/event-stream'});
    res.write(frame({choices: [{index: 0, delta: {content: 'partial'}}]}));
    setImmediate(() => res.destroy());
  });
  assert.equal(result.envelopes[0].payload.complete, false);
  assert.equal(result.envelopes[0].payload.interrupted, true);
  assert.equal(result.envelopes[0].payload.error, 'upstream_incomplete');
  assert.equal(result.envelopes[0].payload.reconstructed_response.choices[0].message.content, 'partial');
});
test('protocol errors are captured without claiming completion', async () => {
  const result = await fixture({raw: true}, res => {
    res.writeHead(200, {'content-type': 'text/event-stream'}); res.end('data: not json\n\n');
  });
  assert.equal(result.envelopes[0].payload.error, 'upstream_protocol');
  assert.equal(result.envelopes[0].payload.complete, false);
});
test('capture rejects public or symlink directories before relay startup', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-trace-policy-'));
  try {
    fs.chmodSync(root, 0o755);
    assert.throws(() => captureFactory({traceCapture: {directory: root, rawAuthorized: true}}), /trace_capture_directory_invalid/);
    fs.chmodSync(root, 0o700); fs.symlinkSync(root, `${root}-link`);
    assert.throws(() => captureFactory({traceCapture: {directory: `${root}-link`, rawAuthorized: true}}), /trace_capture_directory_invalid/);
  } finally { fs.rmSync(`${root}-link`, {force: true}); fs.rmSync(root, {recursive: true}); }
});

test('metadata-only capture records correlation usage and timing without raw fields', async () => {
  const result = await fixture({raw: false}, res => {
    res.writeHead(200, {'content-type': 'text/event-stream'});
    res.end(frame({model: 'observed', choices: [{index: 0, delta: {content: 'private reply'}, finish_reason: 'stop'}],
      usage: {prompt_tokens: 4, completion_tokens: 2, total_tokens: 6}}) + 'data: [DONE]\n\n');
  });
  const envelope = result.envelopes[0], payload = envelope.payload;
  assert.equal(payload.raw_authorized, false);
  assert.equal(payload.complete, true); assert.equal(payload.identity.trace_id, 'trace');
  assert.equal(payload.request_id, result.records[0].request_id);
  assert.equal(payload.usage.total_tokens, 6); assert.equal(payload.observed_model, 'observed');
  assert.ok(payload.ttft_ms >= 0); assert.ok(payload.duration_ms >= payload.ttft_ms);
  for (const key of ['request_body', 'response_chunks', 'events', 'reconstructed_response']) assert.equal(Object.hasOwn(payload, key), false);
  assert.ok(!JSON.stringify(envelope).includes('private prompt')); assert.ok(!JSON.stringify(envelope).includes('private reply'));
  assert.equal(envelope.digest, crypto.createHash('sha256').update(envelope.payload_json).digest('hex'));
});
