'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {spawn} = require('node:child_process');
const {launchBridge} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
const {startOfflineTransport} = require('../lib/agent_runtime/execution/provider_relay.cjs');
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
test('installed OpenCode completes a full offline tool conversation through the private stdio bridge', async () => {
  let requests = 0;
  const server = http.createServer((req, res) => {
    requests++;
    const chunks = []; req.on('data', b => chunks.push(b));
    req.resume(); req.on('end', () => {
      assert.ok((JSON.parse(Buffer.concat(chunks)).tools || []).length <= 128);
      res.writeHead(200, {'content-type': 'text/event-stream'});
      if (requests === 1) {
        res.end('data: '+JSON.stringify({id:'offline',object:'chat.completion.chunk',model:'cx/gpt-6-luna-low',choices:[{index:0,delta:{role:'assistant',tool_calls:[{index:0,id:'offline-read',type:'function',function:{name:'read',arguments:JSON.stringify({filePath:'/workspace/offline.txt'})}}]},finish_reason:null}]})+'\n\ndata: '+JSON.stringify({id:'offline',object:'chat.completion.chunk',choices:[{index:0,delta:{},finish_reason:'tool_calls'}]})+'\n\ndata: [DONE]\n\n');
      } else {
        const body = JSON.parse(Buffer.concat(chunks));
        assert.ok(body.messages.some(m => m.role === 'tool'), 'installed client must submit a real tool result');
        res.end('data: {"id":"offline","object":"chat.completion.chunk","model":"cx/gpt-6-luna-low","choices":[{"index":0,"delta":{"role":"assistant","content":"OFFLINE_GATEWAY_OK"},"finish_reason":null}]}\n\ndata: {"id":"offline","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const fs = require('node:fs');
  const directory = fs.mkdtempSync(require('node:path').join(require('node:os').tmpdir(), 'agru-offline-'));
  const credentialFile = require('node:path').join(directory, 'credential');
  fs.writeFileSync(credentialFile, 'offline-only');
  const origin = 'https://offline.invalid';
  const records = [];
  const relay = startOfflineTransport({origin, approvedOrigins: [origin],
    model: 'cx/gpt-6-luna-low', route: 'offline', timeoutMs: 30000, credentialFile,
    inference: {max_completion_tokens: 128, stream: true, stream_options: {include_usage: true}},
    allowTools: true, identity: {run_id: 'r', architecture: 'a', step_id: 's', attempt: 't'}},
  r => records.push(r), () => {}, {request(url, options, callback) {
    // Assert installed client's effective disabled-tool policy at wire boundary.
    return http.request(`http://127.0.0.1:${server.address().port}/v1/chat/completions`, options, callback);
  }});
  const bridge = await launchBridge({server: relay, timeoutMs: 30000,
    image: 'node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20'});
  try {
    const config = JSON.stringify({$schema: 'https://opencode.ai/config.json', tools: {'*': false, read: true, skill: false}, agent: {title: {disable: true}},
      provider: {mock: {npm: '@ai-sdk/openai-compatible', name: 'mock',
        options: {baseURL: 'http://127.0.0.1:18080/v1', apiKey: 'offline'},
        models: {'cx/gpt-6-luna-low': {name: 'offline', options: {max_completion_tokens: 128}}}}}});
    const script = 'node /bridge.cjs bridge >/tmp/bridge.log & sleep 1; opencode run --format json --model mock/cx/gpt-6-luna-low "Reply OK"';
    const result = await new Promise((resolve, reject) => {
      const child = spawn('docker', ['run', '--rm', '--network', 'none', '--user', '65534:65534',
        '-e', 'HOME=/tmp', '-e', 'OPENCODE_CONFIG_CONTENT=' + config,
        '-v', `${bridge.relayVolume}:/relay`, '-v', `${require('node:path').resolve('lib/agent_runtime/execution/loopback_bridge.cjs')}:/bridge.cjs:ro`,
        '--entrypoint', 'sh', 'agru-agent-sandbox:m12cs1', '-c', script]);
      let output = ''; child.stdout.on('data', b => { output += b; });
      child.stderr.on('data', b => { output += b; }); child.on('error', reject);
      const timer = setTimeout(() => child.kill('SIGKILL'), 12000);
      child.on('exit', status => { clearTimeout(timer); resolve({status, output}); });
    });
    assert.equal(result.status, 0, result.output);
    assert.match(result.output, /OFFLINE_GATEWAY_OK/);
    assert.equal(requests, 2);
  } finally { bridge.close(); server.close(); fs.rmSync(directory, {recursive: true}); }
});
