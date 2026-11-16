// Trusted-boundary HTTPS relay. Agent receives only the Unix socket, never config/secret.
'use strict';
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const crypto = require('node:crypto');
const {StringDecoder} = require('node:string_decoder');
const {isDeepStrictEqual} = require('node:util');
const {observedUsage} = require('./observed_usage.cjs');
const {cumulativeUsage} = require('./cumulative_usage.cjs');
const {gatewayHeartbeatVariant} = require('./gateway_heartbeat.cjs');
const MAX_CONCURRENT_REQUESTS = 2;
function validTools(tools, allowed) {
  if (tools === undefined) return true;
  if (!allowed || !Array.isArray(tools) || tools.length > 128) return false;
  const names = new Set();
  return tools.every(tool => {
    if (!tool || typeof tool !== 'object' || Array.isArray(tool) ||
        Object.keys(tool).some(k => !['type', 'function'].includes(k)) || tool.type !== 'function') return false;
    const fn = tool.function;
    if (!fn || typeof fn !== 'object' || Array.isArray(fn) ||
        Object.keys(fn).some(k => !['name', 'description', 'parameters', 'strict'].includes(k)) ||
        typeof fn.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(fn.name) || names.has(fn.name) ||
        (fn.description !== undefined && (typeof fn.description !== 'string' || fn.description.length > 32768)) ||
        (fn.strict !== undefined && typeof fn.strict !== 'boolean') ||
        !fn.parameters || typeof fn.parameters !== 'object' || Array.isArray(fn.parameters) ||
        fn.parameters.type !== 'object' || Buffer.byteLength(JSON.stringify(fn.parameters)) > 131072) return false;
    names.add(fn.name); return true;
  });
}
// Only the supported chat-completions message shapes cross the trust boundary.
function validMessages(messages, allowTools) {
  const object = value => value && typeof value === 'object' && !Array.isArray(value);
  const keys = (value, allowed) => Object.keys(value).every(key => allowed.includes(key));
  const textContent = value => typeof value === 'string' || (Array.isArray(value) &&
    value.every(part => object(part) && keys(part, ['type', 'text']) &&
      part.type === 'text' && typeof part.text === 'string'));
  const call = value => object(value) && keys(value, ['id', 'type', 'function']) &&
    typeof value.id === 'string' && value.id.length > 0 && value.type === 'function' &&
    object(value.function) && keys(value.function, ['name', 'arguments']) &&
    typeof value.function.name === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value.function.name) &&
    typeof value.function.arguments === 'string';
  return Array.isArray(messages) && messages.length > 0 && messages.every(message => {
    if (!object(message)) return false;
    switch (message.role) {
      case 'system':
      case 'developer':
        return keys(message, ['role', 'content']) && typeof message.content === 'string';
      case 'user':
        return keys(message, ['role', 'content']) && textContent(message.content);
      case 'assistant':
        return keys(message, ['role', 'content', 'tool_calls']) &&
          (typeof message.content === 'string' || (message.content === null && Array.isArray(message.tool_calls) && message.tool_calls.length > 0)) &&
          (message.tool_calls === undefined || (allowTools && Array.isArray(message.tool_calls) && message.tool_calls.length > 0 && message.tool_calls.every(call)));
      case 'tool':
        return allowTools && keys(message, ['role', 'tool_call_id', 'content']) &&
          typeof message.tool_call_id === 'string' && message.tool_call_id.length > 0 && typeof message.content === 'string';
      default: return false;
    }
  });
}
function start(config, audit, authorizeRequest = null) {
  return startTransport(config, audit, authorizeRequest, https);
}
// Explicit trusted-host transport; never enabled by a solver-controlled flag.
function startLocalGateway(config, audit, authorizeRequest) {
  if (typeof authorizeRequest !== 'function' || config.origin !== 'http://127.0.0.1:20128' ||
      !isDeepStrictEqual(config.approvedOrigins, ['http://127.0.0.1:20128'])) {
    throw Error('local_gateway_configuration_invalid');
  }
  const local = JSON.parse(JSON.stringify(config));
  local.origin = 'https://omniroute.invalid';
  local.approvedOrigins = [local.origin];
  return startTransport(local, audit, authorizeRequest, {request(url, options, callback) {
    return http.request('http://127.0.0.1:20128/v1/chat/completions',
      {...options, agent: false}, callback);
  }});
}
function startTransport(config, audit, authorizeRequest, transport) {
  config = JSON.parse(JSON.stringify(config)); // trusted snapshot, not mutable caller state
  const origin = new URL(config.origin);
  if (origin.protocol !== 'https:' || origin.username || origin.password ||
      origin.pathname !== '/' || origin.search || origin.hash ||
      !config.approvedOrigins.includes(origin.origin) ||
      config.model !== 'cx/gpt-6-luna-low' || !Number.isInteger(config.timeoutMs) ||
      config.timeoutMs < 1 || config.timeoutMs > 600000 ||
      !['run_id', 'architecture', 'step_id', 'attempt'].every(k => config.identity[k] != null) ||
      !config.inference || typeof config.inference !== 'object' || Array.isArray(config.inference) ||
      Object.keys(config.inference).some(k => !['max_completion_tokens', 'temperature', 'stream', 'stream_options'].includes(k)) ||
      !Number.isInteger(config.inference.max_completion_tokens) || config.inference.max_completion_tokens < 1 ||
      config.inference.max_completion_tokens > 32000 || config.inference.stream !== true ||
      !isDeepStrictEqual(config.inference.stream_options, {include_usage: true}) ||
      (config.inference.temperature !== undefined && (!Number.isFinite(config.inference.temperature) ||
        config.inference.temperature < 0 || config.inference.temperature > 2)) ||
      (config.allowTools !== undefined && typeof config.allowTools !== 'boolean')) {
    throw new Error('provider_relay_configuration_invalid');
  }
  const credential = fs.readFileSync(config.credentialFile, 'utf8').trim();
  if (!credential || /[\r\n]/.test(credential)) throw new Error('provider_relay_credential_invalid');
  const active = new Set();
  const uploads = new Set();
  let admissionClosed = false;
  let admitted = 0;
  const server = http.createServer((req, res) => {
    const record = {...config.identity, request_id: crypto.randomUUID(),
      session_id: null, session_correlation: 'unavailable', requested_model: config.model,
      provider_route: config.route, gateway_model: null, response_model: null, served_model: null,
      response_models: [], response_model_consistent: null,
      usage: null, observed_usage: null, pricing: null, accounting_complete: false,
      upstream_attempted: false, upstream_response_status: null};
    record.accounting_issues = ['usage_not_reported', 'session_unobservable', 'served_identity_unattested'];
    const began = process.hrtime.bigint();
    let done = false, timer, upstreamRequest;
    const chunks = [];
    function finish(error, status) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      chunks.length = 0;
      record.error = error; record.status = status || null;
      record.duration_ms = Number(process.hrtime.bigint() - began) / 1e6;
      audit(record);
    }
    function reject(status, error) {
      finish(error, status);
      if (res.headersSent) res.destroy();
      else {
        req.pause();
        res.writeHead(status, {'connection': 'close'});
        res.once('finish', () => req.destroy());
        res.end();
      }
    }
    if (admissionClosed) return reject(503, 'attempt_cancelled');
    if (admitted >= MAX_CONCURRENT_REQUESTS) return reject(429, 'concurrency_limit');
    admitted++;
    const cancelUpload = () => { reject(503, 'attempt_cancelled'); req.destroy(); };
    uploads.add(cancelUpload);
    res.once('close', () => { admitted--; uploads.delete(cancelUpload); });
    timer = setTimeout(() => {
      if (!done) reject(504, 'request_timeout');
      if (upstreamRequest) upstreamRequest.destroy();
    }, config.timeoutMs);
    timer.unref();
    if (req.method !== 'POST' || req.url !== '/v1/chat/completions' ||
        req.headers['transfer-encoding']) return reject(400, 'request_policy');
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > 1048576) { reject(413, 'request_size'); req.destroy(); }
      else chunks.push(chunk);
    });
    req.on('aborted', () => finish('client_aborted'));
    req.on('error', () => finish('client_request_error'));
    req.on('end', () => {
      uploads.delete(cancelUpload);
      if (done) return;
      if (admissionClosed) return reject(503, 'attempt_cancelled');
      let body;
      try { body = JSON.parse(Buffer.concat(chunks)); } catch { return reject(400, 'invalid_json'); }
      record.request_fields = body && typeof body === 'object' ? Object.keys(body) : [];
      // No agent-selected endpoint, headers, model override, or inference variant.
      if (!body || typeof body !== 'object' || Array.isArray(body) || body.model !== config.model || Object.keys(body).some(k =>
        !['model', 'messages', 'stream', 'stream_options', 'tools', 'tool_choice', 'temperature', 'max_tokens', 'max_completion_tokens'].includes(k)) ||
        ['temperature', 'max_tokens', 'max_completion_tokens'].some(k => body[k] !== config.inference[k]) ||
        Object.keys(config.inference).some(k => !Object.hasOwn(body, k) || !isDeepStrictEqual(body[k], config.inference[k])) ||
        !validMessages(body.messages, config.allowTools === true) ||
        !validTools(body.tools, config.allowTools === true) ||
        (body.tool_choice !== undefined && (body.tool_choice !== 'auto' || !body.tools?.length)) ||
        (body.stream_options !== undefined && body.stream !== true) ||
        (body.stream !== undefined && body.stream !== true) ||
        (body.stream_options !== undefined && JSON.stringify(body.stream_options) !== '{"include_usage":true}')) {
        return reject(403, 'inference_policy');
      }
      const bytes = Buffer.from(JSON.stringify(body));
      if (authorizeRequest) {
        try { record.reservation = authorizeRequest(bytes, body, record.request_id); }
        catch { return reject(429, 'aggregate_budget_exhausted'); }
      }
      record.upstream_attempted = true;
      const upstream = transport.request(new URL('/v1/chat/completions', origin), {
        method: 'POST', rejectUnauthorized: true, ca: config.caFile ? fs.readFileSync(config.caFile) : undefined,
        headers: {'content-type': 'application/json', 'content-length': bytes.length,
          authorization: `Bearer ${credential}`, 'x-request-id': record.request_id}
      }, response => {
        record.upstream_response_status = response.statusCode;
        if (response.statusCode >= 300 && response.statusCode < 400) {
          response.resume(); reject(502, 'upstream_redirect'); return;
        }
        res.writeHead(response.statusCode, {'content-type': response.headers['content-type'] || 'application/json'});
        let received = 0, pending = '', ended = false, malformed = false;
        const decoder = new StringDecoder('utf8');
        const streaming = (response.headers['content-type'] || '').includes('text/event-stream');
        const diagnostic = record.stream_diagnostic = {streaming, seen_done: false,
          finish_seen: false, malformed: false, stream_ended: false, stream_closed: false,
          malformed_reasons: [], usage_observation_count: 0, usage_totals_distinct: [], heartbeat_count: 0,
          heartbeat_variants: {constant: 0, timestamped_default: 0}, unknown_keepalive_shapes: []};
        function invalid(reason) {
          malformed = true;
          if (!diagnostic.malformed_reasons.includes(reason)) diagnostic.malformed_reasons.push(reason);
        }
        response.on('close', () => { diagnostic.stream_closed = true; });
        let previousCR = false;
        function observe(value) {
          const heartbeatVariant = streaming && gatewayHeartbeatVariant(value);
          if (heartbeatVariant) {
            diagnostic.heartbeat_count = Math.min(1000000, diagnostic.heartbeat_count + 1);
            diagnostic.heartbeat_variants[heartbeatVariant] = Math.min(1000000, diagnostic.heartbeat_variants[heartbeatVariant] + 1);
            return;
          }
          if (value?.model === 'keepalive' && diagnostic.unknown_keepalive_shapes.length < 16) {
            const choice = Array.isArray(value.choices) ? value.choices[0] : null;
            const delta = choice?.delta;
            diagnostic.unknown_keepalive_shapes.push({
              timestamp_kind: Number.isSafeInteger(value.created) ? (value.created > 0 ? 'positive_integer' : value.created === 0 ? 'zero' : 'negative_integer') : 'other',
              default_id: value.id === 'chatcmpl-keepalive',
              extra_top_keys: Object.keys(value).some(k => !['id', 'object', 'created', 'model', 'choices'].includes(k)),
              usage_present: Object.hasOwn(value, 'usage'),
              content_present: Boolean(delta && Object.hasOwn(delta, 'content')),
              tools_present: Boolean(delta && (Object.hasOwn(delta, 'tool_calls') || Object.hasOwn(delta, 'function_call'))),
              nonempty_delta: Boolean(delta && typeof delta === 'object' && Object.keys(delta).length),
              finish_present: choice?.finish_reason != null
            });
          }
          if (!value || typeof value !== 'object') { invalid('response_shape'); return; }
          if (Array.isArray(value.choices) && value.choices.some(choice =>
            choice && typeof choice.finish_reason === 'string')) diagnostic.finish_seen = true;
          if (typeof value.model === 'string') {
            // Response assertion only, never independent served-model attestation.
            if (!/^[A-Za-z0-9][A-Za-z0-9._:/@+#-]{0,255}$/.test(value.model)) {
              record.response_model_consistent = false;
              if (!record.accounting_issues.includes('response_model_invalid')) record.accounting_issues.push('response_model_invalid');
            } else {
              if (record.response_model && record.response_model !== value.model) {
                record.response_model_consistent = false;
                if (!record.accounting_issues.includes('response_model_changed')) record.accounting_issues.push('response_model_changed');
              } else if (record.response_model_consistent === null) record.response_model_consistent = true;
              if (!record.response_models.includes(value.model)) {
                if (record.response_models.length < 128) record.response_models.push(value.model);
                else if (!record.accounting_issues.includes('response_models_truncated')) record.accounting_issues.push('response_models_truncated');
              }
              record.response_model = value.model;
            }
          }
          if (value.usage != null) {
            const usage = value.usage;
            diagnostic.usage_observation_count = Math.min(1000000, diagnostic.usage_observation_count + 1);
            if (Number.isSafeInteger(usage.total_tokens) && usage.total_tokens >= 0 &&
                diagnostic.usage_totals_distinct.length < 128 &&
                !diagnostic.usage_totals_distinct.includes(usage.total_tokens)) diagnostic.usage_totals_distinct.push(usage.total_tokens);
            record.observed_usage = observedUsage(usage);
            const accumulated = cumulativeUsage(record.usage, usage);
            record.usage_reporting_semantics = 'cumulative_observed';
            if (accumulated.error) {
              invalid(accumulated.error);
              record.accounting_issues.push('usage_invalid_or_conflicting');
            } else {
              record.usage = accumulated.usage;
              record.accounting_issues = record.accounting_issues.filter(x => x !== 'usage_not_reported');
            }
          }
        }
        response.on('data', chunk => {
          received += chunk.length;
          if (received > 8388608) { reject(502, 'response_size'); upstream.destroy(); return; }
          let text = decoder.write(chunk);
          if (streaming) {
            // CR is itself a line ending; suppress only an immediately following LF.
            let normalized = '';
            for (const character of text) {
              if (character === '\n' && previousCR) { previousCR = false; continue; }
              normalized += character === '\r' ? '\n' : character;
              previousCR = character === '\r';
            }
            text = normalized;
          }
          pending += text;
          if (pending.length > 1048576) { reject(502, 'response_frame_size'); upstream.destroy(); return; }
          if (streaming) {
            let boundary;
            while ((boundary = pending.indexOf('\n\n')) >= 0) {
              const frame = pending.slice(0, boundary); pending = pending.slice(boundary + 2);
              const data = frame.split('\n').filter(line => line.startsWith('data:'))
                .map(line => line.slice(5).replace(/^ /, '')).join('\n').trim();
              if (data) {
                if (data === '[DONE]') { ended = true; diagnostic.seen_done = true; }
                else try { observe(JSON.parse(data)); } catch { invalid('json_parse'); }
              }
            }
          }
          if (!res.write(chunk)) response.pause();
        });
        res.on('drain', () => response.resume());
        response.on('end', () => {
          diagnostic.stream_ended = true;
          pending += decoder.end();
          if (!streaming) { try { observe(JSON.parse(pending)); } catch { invalid('json_parse'); } }
          if (streaming && !ended) invalid('done_missing');
          if (streaming && pending.trim()) invalid('trailing_nonempty');
          diagnostic.malformed = malformed;
          diagnostic.trailing_nonempty = Boolean(pending.trim());
          if (malformed) record.accounting_issues.push('response_invalid_or_incomplete');
          finish(malformed ? 'upstream_protocol' : response.statusCode >= 400 ? 'upstream_http' : null, response.statusCode);
          res.end();
        });
        response.on('aborted', () => { res.destroy(); finish('upstream_incomplete', response.statusCode); });
        response.on('error', () => { res.destroy(); finish('upstream_incomplete', response.statusCode); });
      });
      active.add(upstream);
      upstreamRequest = upstream;
      upstream.on('close', () => { active.delete(upstream); });
      upstream.on('error', error => { if (!done) reject(502,
        /CERT|TLS|SELF_SIGNED|VERIFY/.test(error.code || '') ? 'upstream_tls' : 'upstream_connection'); });
      res.on('close', () => { if (!res.writableFinished) { finish('client_disconnected'); upstream.destroy(); } });
      upstream.end(bytes);
    });
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.cancelUpstream = () => {
    admissionClosed = true; // one relay instance is scoped to exactly one trusted attempt
    for (const cancel of uploads) cancel();
    for (const request of active) request.destroy();
  };
  server.maxConnections = 8;
  server.on('close', server.cancelUpstream);
  return server;
}
// Explicit test harness dependency injection, never selected by production config.
function startOfflineTransport(config, audit, authorizeRequest, transport) {
  if (!transport || typeof transport.request !== 'function') throw Error('offline_transport_invalid');
  return startTransport(config, audit, authorizeRequest, transport);
}
module.exports = {start, startLocalGateway, startOfflineTransport};
if (require.main === module) {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const server = start(config, record => process.stdout.write(JSON.stringify(record) + '\n'));
  // Deployment must provide a private socket volume shared only with this attempt.
  server.listen(config.socket, () => fs.chmodSync(config.socket, 0o600));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    server.cancelUpstream(); server.close(); server.closeAllConnections();
  });
}
