'use strict';
const {observedUsage} = require('./observed_usage.cjs');
// Explicit cumulative-observation assumption, never a billing verification or sum.
function cumulativeUsage(previous, value) {
  const observed = observedUsage(value);
  if (!observed || ['prompt_tokens', 'completion_tokens', 'total_tokens'].some(k => observed[k] === null)) return {error: 'usage_invalid_counts'};
  if (observed.total_tokens !== observed.prompt_tokens + observed.completion_tokens) return {error: 'usage_total_mismatch'};
  const next = {};
  for (const key of ['prompt_tokens', 'completion_tokens', 'total_tokens']) {
    if (previous && observed[key] < previous[key]) return {error: 'usage_conflict'};
    next[key] = observed[key];
  }
  for (const key of ['prompt_tokens_details', 'completion_tokens_details']) {
    const details = {...previous?.[key]};
    for (const [field, count] of Object.entries(observed[key] || {})) {
      if (count === null) continue;
      if (details[field] !== undefined && count < details[field]) return {error: 'usage_conflict'};
      details[field] = count;
    }
    const limit = key === 'prompt_tokens_details' ? next.prompt_tokens : next.completion_tokens;
    if (Object.values(details).some(count => count > limit)) return {error: 'usage_conflict'};
    if (Object.keys(details).length) next[key] = details;
  }
  return {usage: next};
}
module.exports = {cumulativeUsage};
