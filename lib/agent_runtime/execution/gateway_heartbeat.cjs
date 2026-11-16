'use strict';
const {isDeepStrictEqual} = require('node:util');
// Exact locally evidenced OmniRoute transport heartbeat, not a model-name alias.
const heartbeat = {id: 'chatcmpl-keepalive', object: 'chat.completion.chunk', created: 0,
  model: 'keepalive', choices: [{index: 0, delta: {}, finish_reason: null}]};
function isGatewayHeartbeat(value) { return isDeepStrictEqual(value, heartbeat); }
module.exports = {isGatewayHeartbeat};
