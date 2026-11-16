'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');
const {launch} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
async function main() {
  const file = process.argv[2];
  const privateConfig = JSON.parse(fs.readFileSync(file, 'utf8'));
  const config = privateConfig.gateway;
  if (config.model !== 'cx/gpt-6-luna-low' || config.inference.max_completion_tokens !== 32000) throw Error('token_gateway_scope_invalid');
  let count = 0;
  let pending = null;
  const ledger = message => execFileSync(privateConfig.ruby, [require('node:path').join(__dirname, 'local_token_ledger.rb'), file], {
    input: JSON.stringify(message), timeout: 30000, stdio: ['pipe', 'pipe', 'pipe']
  });
  const gateway = await launch({config, image: privateConfig.image,
    authorizeRequest(bytes) {
      if (pending || ++count > privateConfig.request_limit || bytes.length > 1048576) throw Error('token_gateway_request_limit');
      const id = crypto.randomUUID();
      ledger({action: 'reserve', request_id: id});
      pending = id;
    },
    audit(record) {
      if (pending) {
        ledger({action: 'settle', request_id: pending, observed_model: record.observed_model || null, usage: record.usage || null});
        pending = null;
      }
      process.stdout.write(JSON.stringify({audit: record}) + '\n');
    }});
  process.stdout.write(JSON.stringify({ready: true, relay_volume: gateway.relayVolume}) + '\n');
  const close = () => { gateway.close(); process.exit(0); };
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, close);
  process.stdin.resume(); process.stdin.on('end', close);
}
main().catch(() => { process.stderr.write('local_token_gateway_failed\n'); process.exit(1); });
