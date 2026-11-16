'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {start, startLocalGateway} = require('../lib/agent_runtime/execution/provider_relay.cjs');
test('local transport is explicit, fixed and requires trusted admission', () => {
  const config = {origin: 'http://127.0.0.1:20128', approvedOrigins: ['http://127.0.0.1:20128'],
    model: 'cx/gpt-6-luna-low', timeoutMs: 1000, inference: {max_completion_tokens: 128,
      stream: true, stream_options: {include_usage: true}},
    identity: {run_id: 'r', architecture: 'a', step_id: 's', attempt: 't'}};
  assert.throws(() => start(config, () => {}), /provider_relay_configuration_invalid/);
  assert.throws(() => startLocalGateway(config, () => {}), /local_gateway_configuration_invalid/);
  for (const origin of ['http://localhost:20128', 'http://127.0.0.1:20129',
    'http://example.com', 'https://127.0.0.1:20128']) {
    assert.throws(() => startLocalGateway({...config, origin}, () => {}, () => {}),
      /local_gateway_configuration_invalid/);
  }
  assert.throws(() => startLocalGateway({...config, model: 'fallback'}, () => {}, () => {}),
    /provider_relay_configuration_invalid/);
});
