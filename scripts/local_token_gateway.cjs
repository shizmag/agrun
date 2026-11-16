'use strict';
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const {launch} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
function admission({requestLimit, ledger, emit}) {
  let count = 0;
  const pending = new Set();
  return {
    authorizeRequest(bytes, body, id) {
      if (pending.size) throw Error('token_gateway_request_limit');
      if (count >= requestLimit) { const error = Error('perstage_request_limit'); error.admissionReason = 'perstage_request_limit'; throw error; }
      if (bytes.length > 1048576) throw Error('token_gateway_request_limit');
      ledger({action: 'reserve', request_id: id});
      count++;
      pending.add(id);
      return {request_id: id};
    },
    audit(record) {
      if (pending.has(record.request_id)) {
        const models = [...(Array.isArray(record.response_models) ? record.response_models : []), record.response_model].filter(x => x != null);
        const invalid = (record.accounting_issues || []).some(x => ['response_model_invalid', 'response_models_truncated'].includes(x));
        const unexpected = models.find(x => !['cx/gpt-6-luna-low', 'gpt-6-luna'].includes(x));
        const observed = invalid ? 'untrusted-response-model-observation' : unexpected || models[0] || null;
        try {
          ledger({action: 'settle', request_id: record.request_id, observed_model: observed, usage: record.usage || null});
        } catch (_) {
          // Retain the reservation to fail closed, but never lose transport
          // evidence or expose ledger subprocess diagnostics in the audit.
          emit({...record, ledger_error: 'settlement_failed'});
          return;
        }
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
  const ledger = message => { try { return execFileSync(privateConfig.ruby, [require('node:path').join(__dirname, 'local_token_ledger.rb'), file], {
    input: JSON.stringify(message), timeout: 30000, stdio: ['pipe', 'pipe', 'pipe']
  }); } catch (error) {
    const detail = String(error.stderr || '');
    error.admissionReason = detail.includes('cell_request_limit') ? 'cell_request_limit' : 'global_ledger_admission_failed';
    throw error;
  } };
  const {authorizeRequest, audit} = admission({requestLimit: privateConfig.request_limit, ledger,
    emit: record => process.stdout.write(JSON.stringify({audit: record}) + '\n')});
  let gateway;
  if (privateConfig.offline === true) {
    const {startOfflineTransport} = require('../lib/agent_runtime/execution/provider_relay.cjs');
    const {launchBridge} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
    const {PassThrough} = require('node:stream');
    config.origin = 'https://offline.invalid'; config.approvedOrigins = [config.origin];
    const server = startOfflineTransport(config, audit, authorizeRequest, {request(url, options, callback) {
      const request = new PassThrough(); const chunks = [];
      request.on('data', chunk => chunks.push(chunk));
      request.setTimeout = () => request;
      request.on('finish', () => {
        const response = new PassThrough(); response.statusCode = 200;
        response.headers = {'content-type': 'text/event-stream'};
        callback(response);
        // Four installed-client inference requests per stage: three real reads,
        // then completion. Three-stage solvers exactly exercise the shared cap.
        const body = JSON.parse(Buffer.concat(chunks));
        const tools = body.messages.filter(message => message.role === 'tool');
        const read = (body.tools || []).find(tool => tool.function.name === 'read');
        if (!read && body.tool_choice !== 'none') throw Error('offline_fixture_requires_installed_read_tool');
        const continueTools = !!read && tools.length < 3;
        const delta = continueTools ? {role: 'assistant', tool_calls: [{index: 0, id: `offline-read-${tools.length}`,
          type: 'function', function: {name: 'read', arguments: JSON.stringify({filePath: '/etc/os-release'})}}]} :
          {role: 'assistant', content: 'OFFLINE_ONLY'};
        response.end('data: ' + JSON.stringify({id: 'offline-only', object: 'chat.completion.chunk', model: config.model,
          choices: [{index: 0, delta, finish_reason: continueTools ? 'tool_calls' : 'stop'}],
          usage: {prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}}) + '\n\ndata: [DONE]\n\n');
      });
      return request;
    }});
    gateway = await launchBridge({server, timeoutMs: config.timeoutMs, stageTimeoutMs: privateConfig.stageTimeoutMs, image: privateConfig.image, lifecycle: audit});
  } else gateway = await launch({config, stageTimeoutMs: privateConfig.stageTimeoutMs, image: privateConfig.image, authorizeRequest, audit});
  process.stdout.write(JSON.stringify({ready: true, relay_volume: gateway.relayVolume}) + '\n');
  const close = () => { gateway.close(); process.exit(0); };
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, close);
  process.stdin.resume(); process.stdin.on('end', close);
}
module.exports = {admission};
if (require.main === module) main().catch(() => { process.stderr.write('local_token_gateway_failed\n'); process.exit(1); });
