'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const {spawn, spawnSync} = require('node:child_process');
const crypto = require('node:crypto');
const {startLocalGateway} = require('./provider_relay.cjs');

// Single-use connection/attempt. The caller must reserve its entire cell budget
// durably before invoking this function, and supply per-request admission.
async function launch({config, audit, authorizeRequest, image}) {
  return launchBridge({server: startLocalGateway(config, audit, authorizeRequest),
    timeoutMs: config.timeoutMs, image});
}
// Transport-only bridge also used with an offline simulator; no upstream routing.
async function launchBridge({server, timeoutMs, image}) {
  if (!/^node(?::(?:22|24)-alpine)?@sha256:[a-f0-9]{64}$/.test(image || '')) throw Error('local_gateway_image_invalid');
  const id = `agru-local-${crypto.randomBytes(12).toString('hex')}`;
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-local-'));
  fs.chmodSync(directory, 0o700);
  const socketPath = path.join(directory, 'host.sock');
  let child, connection, closed = false;
  const docker = args => {
    const result = spawnSync('docker', args, {encoding: 'utf8', timeout: 30000});
    if (result.status !== 0) throw Error('local_gateway_docker_failed');
  };
  const close = () => {
    if (closed) return;
    closed = true;
    server.cancelUpstream(); server.close(); server.closeAllConnections();
    if (connection) connection.destroy();
    if (child) child.kill('SIGTERM');
    spawnSync('docker', ['rm', '-f', id], {stdio: 'ignore', timeout: 30000});
    spawnSync('docker', ['volume', 'rm', `${id}-relay`], {stdio: 'ignore', timeout: 30000});
    try { fs.unlinkSync(socketPath); } catch (_) {}
    try { fs.rmdirSync(directory); } catch (_) {}
  };
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject); server.listen(socketPath, resolve);
    });
    docker(['volume', 'create', `${id}-relay`]);
    docker(['create', '-i', '--name', id, '--network', 'none',
      '--read-only', '--cap-drop', 'ALL', '--cap-add', 'CHOWN',
      '--security-opt', 'no-new-privileges', '--memory', '128m', '--cpus', '1', '--pids-limit', '32',
      '-v', `${id}-relay:/relay`, '-v', `${path.join(__dirname, 'local_gateway_stdio.cjs')}:/helper.cjs:ro`,
      image, 'node', '/helper.cjs']);
    child = spawn('docker', ['start', '-ai', id], {stdio: ['pipe', 'pipe', 'pipe']});
    // Establish the private host-side channel immediately. The HTTP server bounds
    // request bodies and deadlines; Node streams provide bounded backpressure.
    connection = net.connect(socketPath);
    child.stdout.pipe(connection); connection.pipe(child.stdin);
    child.stderr.resume(); // never echo potentially sensitive process diagnostics
    child.on('error', close); child.on('exit', close);
    connection.on('error', close); child.stdin.on('error', close);
    const deadline = setTimeout(close, timeoutMs);
    deadline.unref();
    // Wait for helper socket creation, not an arbitrary sleep or live inference.
    let ready = 1;
    for (let attempt = 0; attempt < 40 && ready !== 0 && !closed; attempt++) {
      ready = await new Promise((resolve, reject) => {
      const probe = spawn('docker', ['exec', id, 'node', '-e',
      'const fs=require("fs");let n=0;const t=setInterval(()=>{if(fs.existsSync("/relay/relay.sock")){clearInterval(t);process.exit(0)}if(++n>200)process.exit(1)},25)'],
      {stdio: 'ignore', timeout: 10000});
      probe.on('error', reject); probe.on('exit', resolve);
      });
      if (ready !== 0) await new Promise(resolve => setTimeout(resolve, 100));
    }
    if (ready !== 0) throw Error('local_gateway_not_ready');
    return {relayVolume: `${id}-relay`, image, close};
  } catch (error) { close(); throw error; }
}
module.exports = {launch, launchBridge};
