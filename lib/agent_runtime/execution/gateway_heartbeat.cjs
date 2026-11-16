'use strict';
const {isDeepStrictEqual} = require('node:util');
// Exact locally evidenced OmniRoute transport heartbeat, not a model-name alias.
const heartbeat = {id: 'chatcmpl-keepalive', object: 'chat.completion.chunk', created: 0,
  model: 'keepalive', choices: [{index: 0, delta: {}, finish_reason: null}]};
// Installed OmniRoute open-sse/utils/earlyStreamKeepalive.ts OPENAI_KEEPALIVE_FRAME:
// no application choice, deliberately avoiding a pre-role empty delta.
const earlyStartup = {...heartbeat, choices: []};
function gatewayHeartbeatVariant(value) {
  if (isDeepStrictEqual(value, earlyStartup)) return 'early_startup';
  // Installed open-sse/utils/sseHeartbeat.ts:79-88 uses the same empty choices
  // with epoch seconds. Custom IDs/models are intentionally not generalized.
  if (value && Number.isSafeInteger(value.created) && value.created > 0 &&
      isDeepStrictEqual(value, {...earlyStartup, created: value.created})) return 'timestamped_empty';
  if (isDeepStrictEqual(value, heartbeat)) return 'constant';
  if (value && Number.isSafeInteger(value.created) && value.created > 0 &&
      isDeepStrictEqual(value, {...heartbeat, created: value.created})) return 'timestamped_default';
  return null;
}
function isGatewayHeartbeat(value) { return gatewayHeartbeatVariant(value) !== null; }
module.exports = {isGatewayHeartbeat, gatewayHeartbeatVariant};
