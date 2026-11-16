'use strict';
// Trusted parent reserves the full cell in TokenBudgetLedger BEFORE spawning.
// This entry point does not infer consent or create an alternate ledger.
const fs = require('node:fs');
const {launch} = require('../lib/agent_runtime/execution/local_gateway_launcher.cjs');
async function main() {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  if (config.inference.max_completion_tokens !== 128 || config.model !== 'cx/gpt-6-luna-low') {
    throw Error('local_gateway_smoke_scope_invalid');
  }
  let admitted = false;
  const gateway = await launch({config,
    image: 'node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20',
    authorizeRequest(bytes) {
      if (admitted || bytes.length > 1048576) throw Error('local_gateway_smoke_admission_exhausted');
      admitted = true;
    }, audit: record => process.stdout.write(JSON.stringify({audit: record}) + '\n')});
  process.stdout.write(JSON.stringify({ready: true, relay_volume: gateway.relayVolume, image: gateway.image}) + '\n');
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { gateway.close(); process.exit(0); });
  process.stdin.resume(); process.stdin.on('end', () => { gateway.close(); process.exit(0); });
}
main().catch(() => { process.stderr.write('local_gateway_smoke_failed\n'); process.exitCode = 1; });
