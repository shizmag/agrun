'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {isGatewayHeartbeat, gatewayHeartbeatVariant} = require('../lib/agent_runtime/execution/gateway_heartbeat.cjs');
const fixture = () => ({id: 'chatcmpl-keepalive', object: 'chat.completion.chunk', created: 0,
  model: 'keepalive', choices: [{index: 0, delta: {}, finish_reason: null}]});
test('only the exact evidenced heartbeat structure is excluded from model observations', () => {
  assert.equal(isGatewayHeartbeat(fixture()), true);
  for (const mutate of [v => { v.usage = {}; }, v => { v.extra = true; },
    v => { v.created = -1; }, v => { v.created = 1.5; }, v => { v.id = 'other'; },
    v => { v.model = 'configured-model'; },
    v => { v.choices[0].delta.content = 'actual text'; },
    v => { v.choices[0].delta.tool_calls = []; },
    v => { v.choices[0].finish_reason = 'stop'; },
    v => { v.choices[0].extra = true; }]) {
    const value = fixture(); mutate(value); assert.equal(isGatewayHeartbeat(value), false);
  }
});
test('timestamped heartbeat accepts only the source-backed default identifiers', () => {
  assert.equal(gatewayHeartbeatVariant(fixture()), 'constant');
  for (const created of [1, 1794834000, Number.MAX_SAFE_INTEGER]) {
    assert.equal(gatewayHeartbeatVariant({...fixture(), created}), 'timestamped_default');
  }
  assert.equal(gatewayHeartbeatVariant({...fixture(), created: Number.MAX_SAFE_INTEGER + 1}), null);
});
test('installed OmniRoute early startup uses exactly an empty choices array', () => {
  const startup = {...fixture(), choices: []};
  assert.equal(gatewayHeartbeatVariant(JSON.parse(JSON.stringify(startup))), 'early_startup');
  for (const changed of [{created: 1}, {object: 'other'}, {usage: {}},
    {choices: [{}]}, {choices: null}, {extra: true}, {id: 'other'}]) {
    assert.equal(gatewayHeartbeatVariant({...startup, ...changed}), null);
  }
});
