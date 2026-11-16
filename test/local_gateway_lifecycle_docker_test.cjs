'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {spawn, spawnSync} = require('node:child_process');
const {launchBridge} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
const image = 'node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20';

test('stage lifetime survives request timeout and deadline/cancellation remove Docker resources', async () => {
  for (const cancel of [false, true]) {
    let cancelled = 0;
    const server = http.createServer((req, res) => { req.resume(); req.on('end', () => res.end('ok')); });
    server.cancelUpstream = () => { cancelled++; };
    const bridge = await launchBridge({server, timeoutMs: 500, stageTimeoutMs: 7000, image});
    try {
      const result = await new Promise((resolve, reject) => {
        const script = `const http=require('http');const agent=new http.Agent({keepAlive:true,maxSockets:1});
          const send=()=>new Promise((resolve,reject)=>{http.get({socketPath:'/relay/relay.sock',agent},r=>{r.resume();r.on('end',resolve)}).on('error',reject)});
          (async()=>{await send();await new Promise(r=>setTimeout(r,1200));await send();console.log('SECOND_OK');agent.destroy()})().catch(()=>process.exit(1));`;
        const child = spawn('docker', ['exec', '--user', '65534:65534',
          bridge.relayVolume.replace(/-relay$/, ''), 'node', '-e', script]);
        child.stdout.on('data', () => {
          try { assert.equal(cancelled, 0); } catch (error) { reject(error); }
        });
        child.stderr.resume(); child.on('error', reject); child.on('exit', resolve);
      });
      assert.equal(result, 0, 'bridge must survive idle period longer than provider request timeout');
      if (cancel) bridge.close();
      if (!cancel && cancelled === 0) await new Promise(resolve => server.once('close', resolve));
      assert.equal(cancelled, 1);
      bridge.close();
      assert.equal(cancelled, 1, 'cleanup is idempotent');
      assert.notEqual(spawnSync('docker', ['inspect', bridge.relayVolume.replace(/-relay$/, '')], {stdio: 'ignore'}).status, 0);
      assert.notEqual(spawnSync('docker', ['volume', 'inspect', bridge.relayVolume], {stdio: 'ignore'}).status, 0);
    } finally { bridge.close(); }
  }
});
