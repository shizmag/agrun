// Private host-side capture. Never reads environment consent or serializes headers.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
function captureFactory(config) {
  const option = config.traceCapture;
  if (!option) return () => null;
  if (typeof option.rawAuthorized !== 'boolean') throw Error('trace_capture_authorization_invalid');
  const directory = option.directory;
  if (typeof directory !== 'string' || !path.isAbsolute(directory) || fs.realpathSync(directory) !== directory) {
    throw Error('trace_capture_directory_invalid');
  }
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || (stat.mode & 0o077)) throw Error('trace_capture_directory_invalid');
  return record => new Capture(directory, record, option.rawAuthorized);
}
class Capture {
  constructor(directory, record, rawAuthorized) {
    this.rawAuthorized = rawAuthorized;
    this.directory = directory;
    this.began = process.hrtime.bigint();
    this.payload = {identity: Object.fromEntries(Object.entries(record).filter(([key]) =>
      ['run_id', 'architecture', 'step_id', 'attempt', 'attempt_id', 'cell_id', 'trace_id'].includes(key))),
    request_id: record.request_id, started_at: new Date().toISOString(), request_body: null, response_chunks: [], events: [],
    reconstructed_response: {choices: []}, usage: null, ttft_ms: null};
    this.choices = new Map();
  }
  elapsed() { return Number(process.hrtime.bigint() - this.began) / 1e6; }
  request(body) { if (!this.rawAuthorized) return; this.payload.request_body = JSON.parse(JSON.stringify(body)); }
  chunk(bytes) {
    if (!this.rawAuthorized) return;
    this.payload.response_chunks.push({index: this.payload.response_chunks.length,
      elapsed_ms: this.elapsed(), base64: bytes.toString('base64')});
  }
  event(value, heartbeat = false) {
    if (this.rawAuthorized) this.payload.events.push({index: this.payload.events.length, elapsed_ms: this.elapsed(), value});
    if (heartbeat) return;
    if (!this.rawAuthorized) {
      if (this.payload.ttft_ms === null && (Array.isArray(value?.choices) ? value.choices : []).some(choice => {
        const delta = choice?.delta || choice?.message;
        return delta && (delta.content?.length || delta.reasoning_content?.length || delta.tool_calls?.length || delta.function_call);
      })) this.payload.ttft_ms = this.elapsed();
      return;
    }
    if (typeof value?.model === 'string') this.payload.reconstructed_response.model = value.model;
    if (typeof value?.id === 'string') this.payload.reconstructed_response.id = value.id;
    if (value?.usage != null) this.payload.usage = value.usage;
    for (const choice of Array.isArray(value?.choices) ? value.choices : []) {
      if (!Number.isSafeInteger(choice?.index) || choice.index < 0) continue;
      let output = this.choices.get(choice.index);
      if (!output) {
        output = {index: choice.index, message: {role: 'assistant', content: ''}, finish_reason: null};
        this.choices.set(choice.index, output);
        this.payload.reconstructed_response.choices.push(output);
      }
      const delta = choice.delta || choice.message;
      if (delta && typeof delta === 'object') {
        if (typeof delta.role === 'string') output.message.role = delta.role;
        if (typeof delta.content === 'string') output.message.content += delta.content;
        if (typeof delta.reasoning_content === 'string') output.message.reasoning_content = (output.message.reasoning_content || '') + delta.reasoning_content;
        for (const tool of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
          if (!Number.isSafeInteger(tool?.index) || tool.index < 0) continue;
          output.message.tool_calls ||= [];
          let target = output.message.tool_calls.find(t => t.index === tool.index);
          if (!target) { target = {index: tool.index, function: {name: '', arguments: ''}}; output.message.tool_calls.push(target); }
          if (typeof tool.id === 'string') target.id = tool.id;
          if (typeof tool.type === 'string') target.type = tool.type;
          for (const key of ['name', 'arguments']) if (typeof tool.function?.[key] === 'string') target.function[key] += tool.function[key];
        }
        if (delta.function_call && typeof delta.function_call === 'object') {
          output.message.function_call ||= {name: '', arguments: ''};
          for (const key of ['name', 'arguments']) if (typeof delta.function_call[key] === 'string') output.message.function_call[key] += delta.function_call[key];
        }
        if (this.payload.ttft_ms === null && (delta.content?.length || delta.reasoning_content?.length || delta.tool_calls?.length || delta.function_call)) this.payload.ttft_ms = this.elapsed();
      }
      if (typeof choice.finish_reason === 'string') output.finish_reason = choice.finish_reason;
    }
  }
  finish(record) {
    Object.assign(this.payload, {error: record.error, status: record.status,
      upstream_attempted: record.upstream_attempted, upstream_response_status: record.upstream_response_status,
      complete: record.upstream_attempted === true && record.error === null,
      completed_at: new Date().toISOString(),
      response_model: record.response_model, observed_model: record.response_model,
      duration_ms: record.duration_ms, usage: record.usage, observed_usage: record.observed_usage,
      stream_diagnostic: record.stream_diagnostic || null,
      interrupted: ['upstream_incomplete', 'client_disconnected', 'client_aborted', 'request_timeout', 'attempt_cancelled'].includes(record.error)});
    this.payload.raw_authorized = this.rawAuthorized;
    if (!this.rawAuthorized) {
      for (const key of ['request_body', 'response_chunks', 'events', 'reconstructed_response']) delete this.payload[key];
    }
    const encoded = JSON.stringify(this.payload);
    const digest = crypto.createHash('sha256').update(encoded).digest('hex');
    const file_name = `${this.payload.request_id}-${digest}.json`;
    const target = path.join(this.directory, file_name);
    let fd;
    try {
      fd = fs.openSync(target, 'wx', 0o600);
      // Docker's trusted root writer preserves host ownership for private ingest.
      const owner = fs.statSync(this.directory);
      if (process.getuid() === 0) fs.fchownSync(fd, owner.uid, owner.gid);
      fs.writeFileSync(fd, JSON.stringify({schema: 'provider-trace-capture-v1', digest, payload: this.payload, payload_json: encoded}));
      fs.fsyncSync(fd);
    } catch (error) {
      if (fd !== undefined) { try { fs.unlinkSync(target); } catch {} }
      throw error;
    } finally { if (fd !== undefined) fs.closeSync(fd); }
    return {schema: 'provider-trace-capture-v1', digest, file_name};
  }
}
module.exports = {captureFactory};
