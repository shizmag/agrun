require_relative "test_helper"
require "open3"

# Local HTTPS adversary only; never contacts a provider or uses real credentials.
class ResearchAdversarialControlsTest < Minitest::Test
  def test_truncated_oversized_and_stalled_upstreams_are_not_successful_accounting
    script = <<~'JS'
      const assert = require('node:assert/strict');
      const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
      const https = require('node:https'), http = require('node:http');
      const {execFileSync} = require('node:child_process');
      const {start} = require('./lib/agent_runtime/execution/provider_relay.cjs');
      const watchdog = setTimeout(()=>{console.error('test watchdog');process.exit(2)},10000);
      (async () => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agru-adversarial-'));
        let upstream;
        try {
          const key = path.join(root, 'key'), cert = path.join(root, 'cert'), credentialFile = path.join(root, 'credential');
          execFileSync('openssl', ['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost','-keyout',key,'-out',cert], {stdio:'ignore'});
          fs.writeFileSync(credentialFile, 'synthetic-secret-not-for-client');
          let mode;
          upstream = https.createServer({key:fs.readFileSync(key),cert:fs.readFileSync(cert)}, (req,res) => {
            req.resume();
            if (mode === 'stall') return;
            res.writeHead(200, {'content-type':'text/event-stream'});
            if (mode === 'oversize') res.end('data: ' + 'x'.repeat(1048577));
            else res.end('data: {"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}\n\n');
          });
          await new Promise(r => upstream.listen(0,'127.0.0.1',r));
          const origin = `https://localhost:${upstream.address().port}`;
          const inference = {max_completion_tokens:32000,stream:true,stream_options:{include_usage:true}};
          for (const scenario of ['truncated','oversize','stall']) {
            mode = scenario;
            const records = [];
            const relay = start({origin,approvedOrigins:[origin],model:'cx/gpt-6-luna-low',route:'offline',timeoutMs:250,
              inference,credentialFile,caFile:cert,identity:{run_id:'r',architecture:'test',step_id:'s',attempt:1}}, r => records.push(r));
            await new Promise(r => relay.listen(0,'127.0.0.1',r));
            try {
              const body = JSON.stringify({model:'cx/gpt-6-luna-low',messages:[{role:'user',content:'offline'}],...inference});
              await new Promise((resolve,reject) => {
                const req = http.request({host:'127.0.0.1',port:relay.address().port,method:'POST',path:'/v1/chat/completions'},res => {
                  res.resume(); res.on('end',resolve); res.on('aborted',resolve); res.on('error',resolve);
                });
                req.on('error',reject); req.setTimeout(3000,()=>req.destroy(new Error('test deadline exceeded'))); req.end(body);
              });
              assert.equal(records.length,1);
              assert.equal(records[0].error, {truncated:'upstream_protocol',oversize:'response_frame_size',stall:'request_timeout'}[scenario]);
              assert.equal(records[0].accounting_complete,false);
              assert.ok(!JSON.stringify(records).includes('synthetic-secret-not-for-client'));
              if (scenario === 'truncated') assert.ok(records[0].accounting_issues.includes('response_invalid_or_incomplete'));
              console.log(`${scenario}: rejected/incomplete, credential absent`);
            } finally { relay.cancelUpstream(); relay.closeAllConnections(); await new Promise(r=>relay.close(r)); }
          }
        } finally {
          if (upstream) { upstream.closeAllConnections(); await new Promise(r=>upstream.close(r)); }
          fs.rmSync(root,{recursive:true,force:true});
          clearTimeout(watchdog);
        }
      })().then(()=>process.exit(0)).catch(e=>{console.error(e);process.exit(1)});
    JS
    node = ENV.fetch("AGRU_RESEARCH_NODE", File.executable?("/opt/homebrew/bin/node") ? "/opt/homebrew/bin/node" : "node")
    stdout, stderr, status = Open3.capture3(node, "-e", script, chdir: File.expand_path("..", __dir__))
    assert status.success?, "#{stdout}\n#{stderr}"
    %w[truncated oversize stall].each { |scenario| assert_includes stdout, "#{scenario}: rejected/incomplete, credential absent" }
  end
end
