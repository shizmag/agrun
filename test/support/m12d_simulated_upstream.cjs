// Offline TLS upstream and trusted relay in one network-none container.
const fs = require('node:fs');
const https = require('node:https');
const {start} = require('/provider_relay.cjs');
const secret = fs.readFileSync('/secret/credential', 'utf8').trim();
https.createServer({key: fs.readFileSync('/secret/key.pem'), cert: fs.readFileSync('/secret/cert.pem')}, (req,res) => {
  if (req.headers.authorization !== `Bearer ${secret}`) { res.writeHead(401); res.end(); return; }
  let bytes=''; req.on('data', c => bytes+=c); req.on('end', () => {
    const body=JSON.parse(bytes);
    console.log(JSON.stringify({simulator_authorized:true, model:body.model, fields:Object.keys(body)}));
    res.writeHead(200, {'content-type':'text/event-stream'});
    for (const [delta,finish_reason] of [[{role:'assistant',content:'AGRU_TRANSPORT_OK'},null],[{},'stop']]) {
      res.write('data: '+JSON.stringify({id:'offline-simulator',object:'chat.completion.chunk',
        model:'simulated-not-attested',choices:[{index:0,delta,finish_reason}]})+'\n\n');
    }
    res.write('data: '+JSON.stringify({choices:[],usage:{prompt_tokens:12,completion_tokens:3,total_tokens:15}})+'\n\n');
    res.end('data: [DONE]\n\n');
  });
}).listen(9443,'127.0.0.1', () => {
  const relay=start({origin:'https://localhost:9443', approvedOrigins:['https://localhost:9443'],
    model:'cx/gpt-6-luna-low',route:'OmniRoute-simulated',timeoutMs:10000,
    identity:{run_id:'m12d-installed',architecture:'transport-probe',step_id:'exchange',attempt:1},
    inference:{max_completion_tokens:32000},credentialFile:'/secret/credential',caFile:'/secret/cert.pem'},
    r=>console.log(JSON.stringify(r)));
  relay.listen('/relay/relay.sock',()=>{fs.chmodSync('/relay/relay.sock',0o600); console.log('RELAY_READY');});
  process.on('SIGTERM',()=>{relay.cancelUpstream();process.exit(0);});
});
