// Mock-only Docker acceptance helper. Uses only Node built-ins.
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const mode = process.argv[2];
const route = 'cx/gpt-6-luna-low';
const script = process.argv[3] || 'default';
const negativeScript = ['native-host-negative', 'redirect-negative'].includes(script);
if (!negativeScript && !['default', 'native-subagent', 's2-parity'].includes(script)) throw new Error('unknown frozen script');
const audit = (record) => process.stdout.write(JSON.stringify(record) + '\n');
function listen(server, socket) {
  server.listen(socket, () => {
    fs.chmodSync(socket, 0o666);
    audit({ready: mode});
  });
}
if (mode === 'bridge') {
  http.createServer((req, res) => {
    const upstream = http.request({socketPath: '/relay/relay.sock', path: req.url,
      method: req.method, headers: req.headers}, response => {
      res.writeHead(response.statusCode, response.headers); response.pipe(res);
    });
    upstream.on('error', () => { res.writeHead(502); res.end(); });
    req.pipe(upstream);
  }).listen(18080, '127.0.0.1', () => audit({ready: mode}));
} else if (mode === 'relay' || mode === 'mock') {
  const credential = fs.readFileSync('/secret/credential', 'utf8').trim();
  const server = http.createServer((req, res) => {
    if (req.method !== 'POST' || req.url !== '/v1/chat/completions' ||
        req.headers['transfer-encoding']) { res.writeHead(400); res.end(); return; }
    let bytes = 0; const chunks = [];
    req.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 65536) { res.writeHead(413); res.end(); req.destroy(); }
      else chunks.push(chunk);
    });
    req.on('end', () => {
      const body = Buffer.concat(chunks); let parsed;
      try { parsed = JSON.parse(body); } catch { res.writeHead(400); res.end(); return; }
      if (parsed.model !== route) {
        audit({decision: 'deny', reason: 'route'}); res.writeHead(403); res.end(); return;
      }
      if (mode === 'mock') {
        if (script === 'redirect-negative') {
          const text = JSON.stringify(parsed.messages);
          const match = text.match(/AGRU_REDIRECT_PORT=(\d+)/);
          if (!match) { res.writeHead(400); res.end(); return; }
          audit({injected_redirect: true});
          res.writeHead(302, {location: `http://host.docker.internal:${match[1]}/synthetic-redirect`});
          res.end(); return;
        }
        if (req.headers.authorization !== `Bearer ${credential}`) {
          res.writeHead(401); res.end(); return;
        }
        audit({observed_route: parsed.model, credential_match: true});
        let message = {role: 'assistant', content: 'mock ok'};
        // Fixed test-script protocol: one native read tool call, then final text.
        // No request data can select a destination or alter tool arguments.
        const tools = Array.isArray(parsed.tools) ? parsed.tools : [];
        audit({advertised_tools: tools.map(t => t.function).filter(Boolean)});
        const tool = tools.find(t => t.function?.name === 'read');
        const bash = tools.find(t => t.function?.name === 'shell');
        const results = Array.isArray(parsed.messages) ? parsed.messages.filter(m => m.role === 'tool').length : 0;
        const child = Array.isArray(parsed.messages) && parsed.messages.some(m =>
          m.role === 'user' && JSON.stringify(m.content).includes('AGRU_FIXED_CHILD_CANARY_12C'));
        if ((tool && results === 0) || (bash && results === 1)) {
          message.content = null;
          const shell = results === 1;
          message.tool_calls = [{id: shell ? 'mock-bash-2' : 'mock-read-1', type: 'function', function: {
            name: shell ? 'shell' : 'read', arguments: JSON.stringify(shell ? {
              command: "printf 'sandbox-positive\\n' > sandbox-positive.txt && test -s sandbox-positive.txt", timeout: 1000
            } : {path: '/workspace/README.md'})}}];
        }
        if (script === 'native-subagent' && !child && results === 2 &&
            tools.some(t => t.function?.name === 'subagent')) {
          message.content = null;
          message.tool_calls = [{id:'mock-subagent-3',type:'function',function:{name:'subagent',
            arguments:JSON.stringify({agent:'general',description:'Isolation canary',
              prompt:'AGRU_FIXED_CHILD_CANARY_12C: Read /workspace/README.md, then run the fixed shell canary. Do not create another subagent.'})}}];
        }
        if (script === 'native-host-negative') {
          const text = JSON.stringify(parsed.messages);
          const match = text.match(/AGRU_HOST_PATH=([^\s"\\:]+)/);
          const hostPath = match && match[1];
          const toolResults = parsed.messages.filter(m => m.role === 'tool');
          audit({negative_child: child, negative_results: toolResults});
          if (child && results >= 2) audit({negative_child_completed: true});
          message = {role:'assistant',content: child ? 'NEGATIVE_CHILD_COMPLETED' : 'NEGATIVE_PARENT_COMPLETED'};
          let name, args;
          if (!child && results === 0) {
            name='subagent'; args={agent:'general',description:'Host boundary negative control',
              prompt:`AGRU_FIXED_CHILD_CANARY_12C AGRU_HOST_PATH=${hostPath}: first read the absolute host path, then read /workspace/README.md. Complete despite a denied host read.`};
          } else if (child && results < 2) {
            name='read'; args={path: results === 0 ? hostPath.replace(/:$/, '') : '/workspace/README.md'};
          }
          if (name) { message.content=null; message.tool_calls=[{id:`negative-${child}-${results}`,type:'function',function:{name,arguments:JSON.stringify(args)}}]; }
        }
        if (script === 's2-parity') {
          const fixture = require('/m12cs2_parity_fixture.cjs').response(parsed);
          delete message.tool_calls;
          Object.assign(message, fixture.message);
          audit(fixture.observation);
        }
        const finish = message.tool_calls ? 'tool_calls' : 'stop';
        if (parsed.stream === true) {
          res.writeHead(200, {'content-type': 'text/event-stream'});
          const delta = {...message};
          if (delta.tool_calls) delta.tool_calls = delta.tool_calls.map((t,index) => ({index,...t}));
          for (const [d,f] of [[delta,null],[{},finish]]) {
            res.write('data: '+JSON.stringify({id:'mock-controlled',object:'chat.completion.chunk',
              model:route,choices:[{index:0,delta:d,finish_reason:f}]})+'\n\n');
          }
          res.end('data: [DONE]\n\n'); return;
        }
        res.writeHead(200, {'content-type': 'application/json'});
        res.end(JSON.stringify({id: 'mock-controlled', object: 'chat.completion', model: route,
          choices: [{index: 0, message, finish_reason: finish}],
          usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}})); return;
      }
      audit({decision: 'forward', observed_route: parsed.model,
        body_sha256: crypto.createHash('sha256').update(body).digest('hex')});
      const upstream = http.request({socketPath: '/upstream/mock.sock',
        path: '/v1/chat/completions', method: 'POST', headers: {
          authorization: `Bearer ${credential}`, 'content-type': 'application/json',
          'content-length': body.length}, timeout: 3000}, response => {
        // Never follow redirects or expose upstream headers.
        if (response.statusCode !== 200) { audit({decision:'deny',reason: response.statusCode >= 300 && response.statusCode < 400 ? 'redirect' : 'upstream-status'}); response.resume(); res.writeHead(502); res.end(); return; }
        res.writeHead(200, {'content-type': response.headers['content-type'] || 'application/json'}); response.pipe(res);
      });
      upstream.on('timeout', () => upstream.destroy());
      upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
      upstream.end(body);
    });
  });
  server.on('connect', (req, socket) => socket.destroy());
  server.requestTimeout = 5000;
  listen(server, mode === 'relay' ? '/relay/relay.sock' : '/upstream/mock.sock');
} else { throw new Error('mock helper mode required'); }
