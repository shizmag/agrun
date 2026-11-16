'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {spawn} = require('node:child_process');
const {launchBridge} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
test('real Docker private-volume stdio carries streaming HTTP without container network', async () => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, {'content-type': 'text/event-stream'});
    req.resume();
    req.on('end', () => {
      res.write('data: {"id":"offline","object":"chat.completion.chunk","model":"cx/gpt-6-luna-low","choices":[{"index":0,"delta":{"role":"assistant","content":"offline"},"finish_reason":null}]}\n\n');
      res.end('data: {"id":"offline","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
    });
  });
  server.cancelUpstream = () => {};
  const image = 'node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20';
  const bridge = await launchBridge({server, timeoutMs: 20000, image});
  try {
    const result = await new Promise((resolve, reject) => {
      const child = spawn('docker', ['run', '--rm', '--network', 'none', '--user', '65534:65534',
        '-v', `${bridge.relayVolume}:/relay`, image, 'node', '-e',
        'require("http").get({socketPath:"/relay/relay.sock",path:"/v1/chat/completions"},r=>{r.pipe(process.stdout);r.on("end",()=>process.exit(0))}).on("error",()=>process.exit(1))']);
      let output = '';
      child.stdout.on('data', b => { output += b; });
      child.stderr.resume(); child.on('error', reject);
      child.on('exit', status => resolve({status, output}));
    });
    assert.equal(result.status, 0);
    assert.match(result.output, /offline/);
    assert.match(result.output, /\[DONE\]/);
  } finally { bridge.close(); }
});
test('installed OpenCode completes offline through the same private stdio bridge', async () => {
  let requests = 0;
  const server = http.createServer((req, res) => {
    requests++;
    req.resume(); req.on('end', () => {
      res.writeHead(200, {'content-type': 'text/event-stream'});
      res.end('data: {"id":"offline","object":"chat.completion.chunk","model":"cx/gpt-6-luna-low","choices":[{"index":0,"delta":{"role":"assistant","content":"OFFLINE_GATEWAY_OK"},"finish_reason":null}]}\n\ndata: {"id":"offline","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
    });
  });
  server.cancelUpstream = () => {};
  const bridge = await launchBridge({server, timeoutMs: 30000,
    image: 'node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20'});
  try {
    const config = JSON.stringify({$schema: 'https://opencode.ai/config.json',
      provider: {mock: {npm: '@ai-sdk/openai-compatible', name: 'mock',
        options: {baseURL: 'http://127.0.0.1:18080/v1', apiKey: 'offline'},
        models: {'cx/gpt-6-luna-low': {name: 'offline'}}}}});
    const script = 'node /bridge.cjs bridge >/tmp/bridge.log & sleep 1; opencode run --format json --model mock/cx/gpt-6-luna-low "Reply OK"';
    const result = await new Promise((resolve, reject) => {
      const child = spawn('docker', ['run', '--rm', '--network', 'none', '--user', '65534:65534',
        '-e', 'HOME=/tmp', '-e', 'OPENCODE_CONFIG_CONTENT=' + config,
        '-v', `${bridge.relayVolume}:/relay`, '-v', `${require('node:path').resolve('lib/agent_runtime/execution/loopback_bridge.cjs')}:/bridge.cjs:ro`,
        '--entrypoint', 'sh', 'agru-agent-sandbox:m12cs1', '-c', script]);
      let output = ''; child.stdout.on('data', b => { output += b; });
      child.stderr.on('data', b => { output += b; }); child.on('error', reject);
      child.on('exit', status => resolve({status, output}));
    });
    assert.equal(result.status, 0, result.output);
    assert.match(result.output, /OFFLINE_GATEWAY_OK/);
    assert.ok(requests >= 1); // installed client may also request a session title
  } finally { bridge.close(); }
});
