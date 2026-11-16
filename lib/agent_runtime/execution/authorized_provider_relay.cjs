'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const {start} = require('./provider_relay.cjs');

// Reservations are never refunded, including failed/aborted upstream requests.
// Token bound is explicit provider-contract evidence, not a tokenizer estimate.
function budget(config, clock = Date.now) {
  const q = config.quota;
  const contract = config.reviewedContract;
  if (!q || !contract || contract.version !== 1 || contract.reviewed !== true ||
    contract.provider !== config.origin || contract.model !== config.model ||
    typeof contract.evidence !== 'string' || !contract.evidence.trim() ||
    typeof config.reviewedContractDigest !== 'string' ||
    crypto.createHash('sha256').update(JSON.stringify(contract)).digest('hex') !== config.reviewedContractDigest ||
    !['inputTokensPerByte', 'inputTokenOverhead', 'inputPriceNanosPerMillion', 'outputPriceNanosPerMillion'].every(k => q[k] === contract[k]) ||
    !['requests', 'tokens', 'inputTokensPerByte', 'inputTokenOverhead',
    'inputPriceNanosPerMillion', 'outputPriceNanosPerMillion', 'moneyNanos', 'expiresAt'].every(k =>
    Number.isFinite(q[k]) && q[k] > 0) ||
    !['requests', 'tokens', 'inputTokensPerByte', 'inputTokenOverhead', 'inputPriceNanosPerMillion',
      'outputPriceNanosPerMillion', 'moneyNanos'].every(k => Number.isSafeInteger(q[k])) ||
    q.inputTokensPerByte < 1) throw Error('quota_configuration_invalid');
  let requests = 0, tokens = 0, money = 0n;
  return (bytes, body) => {
    const input = Math.ceil(bytes.length * q.inputTokensPerByte + q.inputTokenOverhead);
    const output = body.max_completion_tokens;
    if (!Number.isSafeInteger(input) || !Number.isSafeInteger(output) || output < 1) throw Error('aggregate_budget_exhausted');
    const numerator = BigInt(input) * BigInt(q.inputPriceNanosPerMillion) + BigInt(output) * BigInt(q.outputPriceNanosPerMillion);
    const cost = (numerator + 999999n) / 1000000n;
    if (!Number.isSafeInteger(input) || !Number.isSafeInteger(output) || output < 1 ||
        clock() >= q.expiresAt || requests + 1 > q.requests || tokens + input + output > q.tokens ||
        money + cost > BigInt(q.moneyNanos)) throw Error('aggregate_budget_exhausted');
    requests++; tokens += input + output; money += cost;
    return {requests, reserved_tokens: tokens, reserved_money_nanos: money.toString()};
  };
}
module.exports = {budget};
if (require.main === module) {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  // Production has no custom CA or TLS override surface.
  if (config.caFile || config.rejectUnauthorized !== undefined) throw Error('tls_override_forbidden');
  const server = start(config, r => process.stdout.write(JSON.stringify(r) + '\n'), budget(config));
  server.listen(config.socket, () => {
    fs.chmodSync(config.socket, 0o600);
    fs.chownSync(config.socket, 65534, 65534);
  });
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    server.cancelUpstream(); server.close(); server.closeAllConnections();
  });
}
