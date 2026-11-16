'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {isGatewayHeartbeat} = require('../lib/agent_runtime/execution/gateway_heartbeat.cjs');
const fixture = () => ({id: 'chatcmpl-keepalive', object: 'chat.completion.chunk', created: 0,
  model: 'keepalive', choices: [{index: 0, delta: {}, finish_reason: null}]});
test('only the exact evidenced heartbeat structure is excluded from model observations', () => {
  assert.equal(isGatewayHeartbeat(fixture()), true);
  for (const mutate of [v => { v.usage = {}; }, v => { v.extra = true; },
    v => { v.created = 1; }, v => { v.id = 'other'; },
    v => { v.choices[0].delta.content = 'actual text'; },
    v => { v.choices[0].delta.tool_calls = []; },
    v => { v.choices[0].finish_reason = 'stop'; },
    v => { v.choices[0].extra = true; }]) {
    const value = fixture(); mutate(value); assert.equal(isGatewayHeartbeat(value), false);
  }
});
