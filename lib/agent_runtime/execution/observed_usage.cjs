'use strict';
// Provider-reported numeric observations, not validated billing or attestation.
function observedUsage(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const result = {};
  const numeric = n => Number.isSafeInteger(n) && n >= 0;
  for (const key of ['prompt_tokens', 'completion_tokens', 'total_tokens']) {
    result[key] = numeric(value[key]) ? value[key] : null;
  }
  for (const [key, fields] of Object.entries({
    prompt_tokens_details: ['cached_tokens', 'audio_tokens'],
    completion_tokens_details: ['reasoning_tokens', 'audio_tokens', 'accepted_prediction_tokens', 'rejected_prediction_tokens']
  })) {
    const details = value[key];
    result[key] = details && typeof details === 'object' && !Array.isArray(details)
      ? Object.fromEntries(fields.map(field => [field, numeric(details[field]) ? details[field] : null])) : null;
  }
  return result;
}
module.exports = {observedUsage};
