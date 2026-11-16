'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const {execFileSync} = require('node:child_process');
const {start} = require('../lib/agent_runtime/execution/provider_relay.cjs');
const inference = {max_completion_tokens: 32000, stream: true, stream_options: {include_usage: true}};
test('unfinished uploads have bounded admission, deadlines and reusable slots', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-admission-'));
  const credentialFile = path.join(root, 'credential'); fs.writeFileSync(credentialFile, 'offline-only');
  const records = [], clients = [];
  const origin = 'https://localhost:1';
  const relay = start({origin, approvedOrigins: [origin], model: 'cx/gpt-6-luna-low',
    route: 'offline', timeoutMs: 300, inference, credentialFile,
    identity: {run_id: 'run', architecture: 'arm', step_id: 'step', attempt: 'attempt'}}, r => records.push(r));
  const socketPath = path.join(root, 'relay.sock');
  await new Promise(resolve => relay.listen(socketPath, resolve));
  function upload() {
    let client;
    const result = new Promise((resolve, reject) => {
      client = http.request({socketPath, method: 'POST', path: '/v1/chat/completions',
        headers: {'content-length': 1048576}}, res => {
        res.resume(); res.on('end', () => resolve(res.statusCode));
      });
      client.on('error', reject); client.flushHeaders(); client.write('{');
    });
    clients.push(client); return result;
  }
  try {
    const held = Array.from({length: 2}, upload);
    assert.equal(await upload(), 429);
    assert.deepEqual(await Promise.all(held), [504, 504]);
    const next = upload();
    assert.equal(await next, 504, 'expired uploads must release capacity');
    const cancelled = upload();
    // Allow the local server to accept the headers before cancellation.
    await new Promise(resolve => setTimeout(resolve, 20));
    relay.cancelUpstream();
    assert.equal(await cancelled, 503);
    assert.equal(await upload(), 503);
    assert.equal(records.filter(r => r.error === 'concurrency_limit').length, 1);
    assert.equal(records.filter(r => r.error === 'request_timeout').length, 3);
    assert.ok(records.every(r => r.attempt === 'attempt' && r.request_id));
  } finally {
    clients.forEach(client => client.destroy()); relay.cancelUpstream();
    await new Promise(resolve => relay.close(resolve));
    fs.rmSync(root, {recursive: true, force: true});
  }
});
test('offline HTTPS enforces TLS, rejects redirects and parses CR-framed SSE', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-tls-'));
  const key = path.join(root, 'key.pem'), cert = path.join(root, 'cert.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=localhost', '-keyout', key, '-out', cert], {stdio: 'ignore'});
  const credentialFile = path.join(root, 'credential'); fs.writeFileSync(credentialFile, 'offline-only');
  let mode = 'sse', hits = 0;
  const upstream = https.createServer({key: fs.readFileSync(key), cert: fs.readFileSync(cert)}, (req, res) => {
    hits++; req.resume();
    if (mode === 'redirect') { res.writeHead(307, {location: 'https://example.invalid/steal'}); res.end(); return; }
    res.writeHead(200, {'content-type': 'text/event-stream'});
    res.write('data: {"model":"simulated","usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}\r');
    setImmediate(() => res.end('\n\rdata: [DONE]\r\r'));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const origin = `https://localhost:${upstream.address().port}`;
  async function exchange(trust, fields = {}, allowTools = false) {
    const records = [];
    const relay = start({origin, approvedOrigins: [origin], model: 'cx/gpt-6-luna-low',
      route: 'offline', timeoutMs: 1000, inference, credentialFile, allowTools,
      ...(trust ? {caFile: cert} : {}),
      identity: {run_id: 'offline', architecture: 'test', step_id: 'tls', attempt: 1}}, r => records.push(r));
    await new Promise(resolve => relay.listen(0, '127.0.0.1', resolve));
    try {
      const body = JSON.stringify({model: 'cx/gpt-6-luna-low', messages: [{role: 'user', content: 'offline'}], ...inference, ...fields});
      const status = await new Promise((resolve, reject) => {
        const req = http.request({host: '127.0.0.1', port: relay.address().port, method: 'POST',
          path: '/v1/chat/completions', headers: {'content-length': Buffer.byteLength(body)}}, res => {
          res.resume(); res.on('end', () => resolve(res.statusCode));
        }); req.on('error', reject); req.end(body);
      });
      return {status, record: records[0]};
    } finally { await new Promise(resolve => relay.close(resolve)); }
  }
  try {
    const denied = await exchange(false);
    assert.equal(denied.status, 502); assert.equal(hits, 0);
    const streamed = await exchange(true);
    assert.equal(streamed.status, 200);
    assert.deepEqual(streamed.record.usage, {prompt_tokens: 12, completion_tokens: 3, total_tokens: 15});
    mode = 'redirect';
    const redirected = await exchange(true);
    assert.equal(redirected.status, 502); assert.equal(redirected.record.error, 'upstream_redirect');
    assert.equal(hits, 2);
    mode = 'sse';
    const tool = {type: 'function', function: {name: 'read_file', parameters: {type: 'object'}}};
    for (const fields of [
      {tools: [tool], tool_choice: 'required'}, {tools: [tool], tool_choice: 'none'},
      {tools: [tool], tool_choice: {type: 'function', function: {name: 'read_file'}}},
      {tools: [tool, tool]}, {tools: [null]}, {tools: [{type: 'web_search'}]},
      {tools: [{...tool, function: {...tool.function, parameters: null}}]},
      {tools: Array(129).fill(tool)}, {tools: [], tool_choice: 'auto'}]) {
      assert.equal((await exchange(true, fields, true)).status, 403);
    }
    assert.equal(hits, 2, 'invalid tools never reach upstream');
    assert.equal((await exchange(true, {tools: [tool], tool_choice: 'auto'}, true)).status, 200);
    assert.equal(hits, 3);
  } finally {
    await new Promise(resolve => upstream.close(resolve));
    fs.rmSync(root, {recursive: true, force: true});
  }
});
test('cancellation interrupts an unfinished upload and closes admission', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-upload-'));
  const credentialFile = path.join(root, 'credential');
  fs.writeFileSync(credentialFile, 'offline-only');
  const records = [];
  const server = start({origin: 'https://localhost:9443', approvedOrigins: ['https://localhost:9443'],
    model: 'cx/gpt-6-luna-low', route: 'offline', timeoutMs: 10000,
    identity: {run_id: 'offline', architecture: 'test', step_id: 'upload', attempt: 1},
    inference, credentialFile}, record => records.push(record));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let request;
  try {
    const received = new Promise(resolve => server.once('request', resolve));
    const closed = new Promise(resolve => {
      request = http.request({host: '127.0.0.1', port: server.address().port,
        path: '/v1/chat/completions', method: 'POST', headers: {'content-length': 10000}}, response => response.resume());
      request.on('error', () => {});
      request.on('close', resolve);
      request.write('{');
    });
    await received;
    server.cancelUpstream();
    await Promise.race([closed, new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error('upload cancellation stalled')), 1000);
      timer.unref();
    })]);
    assert.equal(records.length, 1);
    assert.equal(records[0].error, 'attempt_cancelled');
    assert.equal(records[0].status, 503);
    assert.equal(records[0].usage, null);
  } finally {
    request?.destroy();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, {recursive: true, force: true});
  }
});
test('configuration fails closed and rejected requests are attributable without credentials', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-relay-'));
  const credentialFile = path.join(root, 'credential');
  fs.writeFileSync(credentialFile, 'synthetic-test-secret');
  const config = {origin: 'https://localhost:9443', approvedOrigins: ['https://localhost:9443'],
    model: 'cx/gpt-6-luna-low', route: 'OmniRoute', timeoutMs: 100,
    identity: {run_id: 'offline', architecture: 'transport-test', step_id: 'probe', attempt: 1},
    inference, credentialFile};
  for (const origin of ['http://localhost:9443', 'https://evil.invalid', 'https://localhost:9443/other']) {
    assert.throws(() => start({...config, origin}, () => {}), /configuration_invalid/);
  }
  for (const invalid of [{}, {...inference, max_completion_tokens: 0},
    {...inference, max_completion_tokens: 32001}, {...inference, stream: false},
    {...inference, stream_options: {}}, {...inference, seed: 1}]) {
    assert.throws(() => start({...config, inference: invalid}, () => {}), /configuration_invalid/);
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
    for (const extra of [{}, {messages: []}, {messages: [null]},
      {messages: [{}], stream_options: {include_usage: false}},
      {messages: [{}], tools: {}}, {messages: [{}], temperature: 0.5}]) {
      const body = JSON.stringify({model: config.model, ...inference, ...extra});
      const rejected = await new Promise((resolve, reject) => {
        const req = http.request({host: '127.0.0.1', port: server.address().port,
          path: '/v1/chat/completions', method: 'POST', headers: {'content-length': Buffer.byteLength(body)}}, res => {
          res.resume(); res.on('end', () => resolve(res.statusCode));
        }); req.on('error', reject); req.end(body);
      });
      assert.equal(rejected, 403);
    }
    const base = {model: config.model, messages: [{role: 'user', content: 'offline'}], ...inference};
    const attacks = Object.keys(inference).map(key => {
      const body = {...base}; delete body[key]; return body;
    });
    attacks.push({...base, max_completion_tokens: 1}, {...base, max_tokens: 1},
      {...base, stream: false}, {...base, seed: 1},
      {...base, tools: [{type: 'function', function: {name: 'run', parameters: {type: 'object'}}}]},
      {...base, tool_choice: 'required'}, {...base, tool_choice: 'auto'});
    for (const attack of attacks) {
      const body = JSON.stringify(attack);
      const status = await new Promise((resolve, reject) => {
        const req = http.request({host: '127.0.0.1', port: server.address().port,
          path: '/v1/chat/completions', method: 'POST', headers: {'content-length': Buffer.byteLength(body)}}, res => {
          res.resume(); res.on('end', () => resolve(res.statusCode));
        }); req.on('error', reject); req.end(body);
      });
      assert.equal(status, 403);
    }
    assert.equal(records[0].usage, null);
    assert.equal(records[0].served_model, null);
    assert.equal(records[0].accounting_complete, false);
    assert.equal(JSON.stringify(records).includes('synthetic-test-secret'), false);
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.unlinkSync(credentialFile); fs.rmdirSync(root);
  }
});
