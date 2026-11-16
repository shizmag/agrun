'use strict';
const fs = require('node:fs');
const {start} = require('./provider_relay.cjs');

// Reservations are never refunded, including failed/aborted upstream requests.
// Token bound is explicit provider-contract evidence, not a tokenizer estimate.
function budget(config, clock = Date.now) {
  const q = config.quota;
  if (!q || !['requests', 'tokens', 'inputTokensPerByte', 'inputTokenOverhead',
    'inputPricePerMillion', 'outputPricePerMillion', 'money', 'expiresAt'].every(k =>
    Number.isFinite(q[k]) && q[k] > 0) ||
    !Number.isSafeInteger(q.requests) || !Number.isSafeInteger(q.tokens) ||
    !q.pricingEvidence || !q.tokenBoundEvidence) throw Error('quota_configuration_invalid');
  let requests = 0, tokens = 0, money = 0;
  return (bytes, body) => {
    const input = Math.ceil(bytes.length * q.inputTokensPerByte + q.inputTokenOverhead);
    const output = body.max_completion_tokens;
    const cost = (input * q.inputPricePerMillion + output * q.outputPricePerMillion) / 1e6;
    if (!Number.isSafeInteger(input) || !Number.isSafeInteger(output) || output < 1 ||
        clock() >= q.expiresAt || requests + 1 > q.requests || tokens + input + output > q.tokens ||
        money + cost > q.money) throw Error('aggregate_budget_exhausted');
    requests++; tokens += input + output; money += cost;
    return {requests, reserved_tokens: tokens, reserved_money: money};
  };
}
module.exports = {budget};
if (require.main === module) {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  // Production has no custom CA or TLS override surface.
  if (config.caFile || config.rejectUnauthorized !== undefined) throw Error('tls_override_forbidden');
  const server = start(config, r => process.stdout.write(JSON.stringify(r) + '\n'), budget(config));
  server.listen(config.socket, () => fs.chmodSync(config.socket, 0o600));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    server.cancelUpstream(); server.close(); server.closeAllConnections();
  });
}
