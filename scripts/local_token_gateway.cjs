'use strict';
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const {launch} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
function admission({requestLimit, ledger, emit}) {
  let count = 0;
  const pending = new Set();
  return {
    authorizeRequest(bytes, body, id) {
      if (pending.size || count >= requestLimit || bytes.length > 1048576) throw Error('token_gateway_request_limit');
      ledger({action: 'reserve', request_id: id});
      count++;
      pending.add(id);
      return {request_id: id};
    },
    audit(record) {
      if (pending.has(record.request_id)) {
        ledger({action: 'settle', request_id: record.request_id, observed_model: record.response_model || null, usage: record.usage || null});
        pending.delete(record.request_id);
      }
      emit(record);
    }
  };
}
async function main() {
  const file = process.argv[2];
  const privateConfig = JSON.parse(fs.readFileSync(file, 'utf8'));
  const config = privateConfig.gateway;
  if (config.model !== 'cx/gpt-6-luna-low' || config.inference.max_completion_tokens !== 32000) throw Error('token_gateway_scope_invalid');
  const ledger = message => execFileSync(privateConfig.ruby, [require('node:path').join(__dirname, 'local_token_ledger.rb'), file], {
    input: JSON.stringify(message), timeout: 30000, stdio: ['pipe', 'pipe', 'pipe']
  });
  const {authorizeRequest, audit} = admission({requestLimit: privateConfig.request_limit, ledger,
    emit: record => process.stdout.write(JSON.stringify({audit: record}) + '\n')});
  let gateway;
  if (privateConfig.offline === true) {
    const {startOfflineTransport} = require('../lib/agent_runtime/execution/provider_relay.cjs');
    const {launchBridge} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
    const {PassThrough} = require('node:stream');
    config.origin = 'https://offline.invalid'; config.approvedOrigins = [config.origin];
    const server = startOfflineTransport(config, audit, authorizeRequest, {request(url, options, callback) {
      const request = new PassThrough(); request.resume();
      request.setTimeout = () => request;
      request.on('finish', () => {
        const response = new PassThrough(); response.statusCode = 200;
        response.headers = {'content-type': 'text/event-stream'};
        callback(response);
        response.end('data: ' + JSON.stringify({id: 'offline-only', object: 'chat.completion.chunk', model: config.model,
          choices: [{index: 0, delta: {role: 'assistant', content: 'OFFLINE_ONLY'}, finish_reason: 'stop'}],
          usage: {prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}}) + '\n\ndata: [DONE]\n\n');
      });
      return request;
    }});
    server.keepAliveTimeout = config.timeoutMs;
    gateway = await launchBridge({server, timeoutMs: config.timeoutMs, image: privateConfig.image});
  } else gateway = await launch({config, image: privateConfig.image, authorizeRequest, audit});
  process.stdout.write(JSON.stringify({ready: true, relay_volume: gateway.relayVolume}) + '\n');
  const close = () => { gateway.close(); process.exit(0); };
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, close);
  process.stdin.resume(); process.stdin.on('end', close);
}
module.exports = {admission};
if (require.main === module) main().catch(() => { process.stderr.write('local_token_gateway_failed\n'); process.exit(1); });
