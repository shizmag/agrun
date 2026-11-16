'use strict';
const fs = require('node:fs');
const https = require('node:https');
const {start} = require('/provider_relay.cjs');
const config = JSON.parse(fs.readFileSync('/secret/config.json', 'utf8'));
const secret = fs.readFileSync(config.credentialFile, 'utf8').trim();
https.createServer({key: fs.readFileSync('/secret/key.pem'), cert: fs.readFileSync('/secret/cert.pem')}, (req, res) => {
  if (req.method !== 'POST' || req.url !== '/v1/chat/completions' ||
      req.headers.authorization !== `Bearer ${secret}`) { res.writeHead(403); res.end(); return; }
  let size = 0;
  req.on('data', chunk => { size += chunk.length; if (size > 1048576) req.destroy(); });
  req.on('end', () => {
    res.writeHead(200, {'content-type': 'text/event-stream'});
    for (const [delta, finish_reason] of [[{role: 'assistant', content: 'AGRU_TRANSPORT_OK'}, null], [{}, 'stop']]) {
      res.write('data: ' + JSON.stringify({id: 'offline-simulator', object: 'chat.completion.chunk',
        model: 'simulated-not-attested', choices: [{index: 0, delta, finish_reason}]}) + '\n\n');
    }
    res.write('data: ' + JSON.stringify({choices: [], usage: {prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}}) + '\n\n');
    res.end('data: [DONE]\n\n');
  });
}).listen(9443, '127.0.0.1', () => {
  const relay = start(config, record => console.log(JSON.stringify(record)));
  relay.listen('/relay/relay.sock', () => {
    fs.chmodSync('/relay/relay.sock', 0o600);
    console.log('RELAY_READY');
  });
});
