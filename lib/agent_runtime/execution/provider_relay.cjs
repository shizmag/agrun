// Trusted-boundary HTTPS relay. Agent receives only the Unix socket, never config/secret.
'use strict';
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const crypto = require('node:crypto');
const {StringDecoder} = require('node:string_decoder');
function start(config, audit) {
  config = JSON.parse(JSON.stringify(config)); // trusted snapshot, not mutable caller state
  const origin = new URL(config.origin);
  if (origin.protocol !== 'https:' || origin.username || origin.password ||
      origin.pathname !== '/' || origin.search || origin.hash ||
      !config.approvedOrigins.includes(origin.origin) ||
      config.model !== 'cx/gpt-6-luna-low' || !Number.isInteger(config.timeoutMs) ||
      config.timeoutMs < 1 || config.timeoutMs > 600000 ||
      !['run_id', 'architecture', 'step_id', 'attempt'].every(k => config.identity[k] != null)) {
    throw new Error('provider_relay_configuration_invalid');
  }
  const credential = fs.readFileSync(config.credentialFile, 'utf8').trim();
  if (!credential || /[\r\n]/.test(credential)) throw new Error('provider_relay_credential_invalid');
  const active = new Set();
  let admissionClosed = false;
  let admitted = 0;
  const server = http.createServer((req, res) => {
    const record = {...config.identity, request_id: crypto.randomUUID(),
      session_id: null, session_correlation: 'unavailable', requested_model: config.model,
      provider_route: config.route, gateway_model: null, served_model: null,
      usage: null, pricing: null, accounting_complete: false};
    record.accounting_issues = ['usage_not_reported', 'session_unobservable', 'served_identity_unattested'];
    const began = process.hrtime.bigint();
    let done = false;
    function finish(error, status) {
      if (done) return;
      done = true;
      record.error = error; record.status = status || null;
      record.duration_ms = Number(process.hrtime.bigint() - began) / 1e6;
      audit(record);
    }
    function reject(status, error) {
      finish(error, status);
      if (res.headersSent) res.destroy();
      else { res.writeHead(status); res.end(); }
    }
    if (admissionClosed || admitted >= 2) return reject(503, 'admission_closed_or_capacity');
    admitted++;
    res.once('close', () => { admitted--; });
    if (req.method !== 'POST' || req.url !== '/v1/chat/completions' ||
        req.headers['transfer-encoding']) return reject(400, 'request_policy');
    let size = 0; const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > 1048576) { reject(413, 'request_size'); req.destroy(); }
      else chunks.push(chunk);
    });
    req.on('aborted', () => finish('client_aborted'));
    req.on('error', () => finish('client_request_error'));
    req.on('end', () => {
      if (done) return;
      if (admissionClosed) return reject(503, 'attempt_cancelled');
      let body;
      try { body = JSON.parse(Buffer.concat(chunks)); } catch { return reject(400, 'invalid_json'); }
      record.request_fields = body && typeof body === 'object' ? Object.keys(body) : [];
      // No agent-selected endpoint, headers, model override, or inference variant.
      if (!body || typeof body !== 'object' || Array.isArray(body) || body.model !== config.model || Object.keys(body).some(k =>
        !['model', 'messages', 'stream', 'stream_options', 'tools', 'tool_choice', 'temperature', 'max_tokens', 'max_completion_tokens'].includes(k)) ||
        ['temperature', 'max_tokens', 'max_completion_tokens'].some(k => body[k] !== config.inference[k]) ||
        Object.keys(config.inference).some(k => JSON.stringify(body[k]) !== JSON.stringify(config.inference[k])) ||
        (body.stream !== undefined && body.stream !== true) ||
        (body.stream_options !== undefined && JSON.stringify(body.stream_options) !== '{"include_usage":true}')) {
        return reject(403, 'inference_policy');
      }
      const bytes = Buffer.from(JSON.stringify(body));
      const upstream = https.request(new URL('/v1/chat/completions', origin), {
        method: 'POST', rejectUnauthorized: true, ca: config.caFile ? fs.readFileSync(config.caFile) : undefined,
        headers: {'content-type': 'application/json', 'content-length': bytes.length,
          authorization: `Bearer ${credential}`, 'x-request-id': record.request_id}
      }, response => {
        if (response.statusCode >= 300 && response.statusCode < 400) {
          response.resume(); reject(502, 'upstream_redirect'); return;
        }
        res.writeHead(response.statusCode, {'content-type': response.headers['content-type'] || 'application/json'});
        let received = 0, pending = '', ended = false, malformed = false;
        const decoder = new StringDecoder('utf8');
        const streaming = (response.headers['content-type'] || '').includes('text/event-stream');
        function observe(value) {
          if (!value || typeof value !== 'object') { malformed = true; return; }
          if (typeof value.model === 'string') {
            // Response assertion only, never independent served-model attestation.
            if (record.response_model && record.response_model !== value.model) malformed = true;
            record.response_model = value.model;
          }
          if (value.usage != null) {
            const usage = value.usage;
            if (!['prompt_tokens', 'completion_tokens', 'total_tokens'].every(k => Number.isSafeInteger(usage[k]) && usage[k] >= 0) ||
                usage.total_tokens !== usage.prompt_tokens + usage.completion_tokens ||
                (record.usage && JSON.stringify(record.usage) !== JSON.stringify(usage))) {
              record.accounting_issues.push('usage_invalid_or_conflicting'); malformed = true;
            } else {
              record.usage = usage;
              record.accounting_issues = record.accounting_issues.filter(x => x !== 'usage_not_reported');
            }
          }
        }
        response.on('data', chunk => {
          received += chunk.length;
          if (received > 8388608) { reject(502, 'response_size'); upstream.destroy(); return; }
          pending += decoder.write(chunk);
          pending = pending.replace(/\r\n/g, '\n');
          if (pending.length > 1048576) { reject(502, 'response_frame_size'); upstream.destroy(); return; }
          if (streaming) {
            let boundary;
            while ((boundary = pending.indexOf('\n\n')) >= 0) {
              const frame = pending.slice(0, boundary); pending = pending.slice(boundary + 2);
              const data = frame.split('\n').filter(line => line.startsWith('data:'))
                .map(line => line.slice(5).replace(/^ /, '')).join('\n').trim();
              if (data) {
                if (data === '[DONE]') ended = true;
                else try { observe(JSON.parse(data)); } catch { malformed = true; }
              }
            }
          }
          if (!res.write(chunk)) response.pause();
        });
        res.on('drain', () => response.resume());
        response.on('end', () => {
          if (!streaming) { try { observe(JSON.parse(pending)); } catch { malformed = true; } }
          if (streaming && (!ended || pending.trim())) malformed = true;
          if (malformed) record.accounting_issues.push('response_invalid_or_incomplete');
          finish(malformed ? 'upstream_protocol' : response.statusCode >= 400 ? 'upstream_http' : null, response.statusCode);
          res.end();
        });
        response.on('aborted', () => { res.destroy(); finish('upstream_incomplete', response.statusCode); });
        response.on('error', () => { res.destroy(); finish('upstream_incomplete', response.statusCode); });
      });
      active.add(upstream);
      const timer = setTimeout(() => { upstream.destroy(); if (!done) reject(504, 'upstream_timeout'); }, config.timeoutMs);
      upstream.on('close', () => { clearTimeout(timer); active.delete(upstream); });
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
    for (const request of active) request.destroy();
  };
  server.maxConnections = 8;
  server.on('close', server.cancelUpstream);
  return server;
}
module.exports = {start};
if (require.main === module) {
  const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const server = start(config, record => process.stdout.write(JSON.stringify(record) + '\n'));
  // Deployment must provide a private socket volume shared only with this attempt.
  server.listen(config.socket, () => fs.chmodSync(config.socket, 0o600));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    server.cancelUpstream(); server.close(); server.closeAllConnections();
  });
}
