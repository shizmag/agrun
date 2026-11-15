require "minitest/autorun"
require_relative "support/m12c_relay_docker"

class M12cMockRelayTest < Minitest::Test
  def test_network_disabled_relay_and_adversarial_client
    skip "set AGRU_M12C_MOCK_DOCKER=1 for mock-only Docker acceptance" unless ENV["AGRU_M12C_MOCK_DOCKER"] == "1"
    relay = M12cRelayDocker.new
    begin
      relay.start
      canary_ip = relay.start_canary
      canary_probe = <<~JS
        const net=require('net'),udp=require('dgram').createSocket('udp4');
        const host=#{canary_ip.inspect};
        let tcp=false,dns=false;
        const s=net.connect({host,port:18081},()=>{tcp=true;s.destroy()});s.on('error',()=>{});
        udp.on('message',()=>{dns=true});udp.on('error',()=>{});
        udp.send(Buffer.from('controlled-dns-canary'),18082,host,()=>{});
        setTimeout(()=>{udp.close();s.destroy();console.log(JSON.stringify({tcp,dns}));},700);
      JS
      positive = relay.command("run", "--rm", "--pull=never", "--network=bridge", relay.image, "node", "-e", canary_probe)
      assert_includes positive, '{"tcp":true,"dns":true}'
      before = relay.logs("canary")
      negative = relay.command(*(relay.agent_argv + ["node", "-e", canary_probe]))
      assert_includes negative, '{"tcp":false,"dns":false}'
      assert_equal before, relay.logs("canary"), "network-none agent must not reach controlled TCP/UDP service"
      probe = <<~'JS'
        const http = require('node:http'), net = require('node:net'), fs = require('node:fs');
        async function request(model, path='/v1/chat/completions', extra={}) {
          return await new Promise((resolve,reject) => {
            const body=JSON.stringify({model,messages:[],...extra});
            const r=http.request({socketPath:'/relay/relay.sock',method:'POST',path,
              headers:{authorization:'Bearer attacker','content-length':Buffer.byteLength(body)}},s=>{
                let text='';s.on('data',c=>text+=c);s.on('end',()=>resolve(extra.stream ? text : s.statusCode));});
            r.on('error',reject);r.end(body);
          });
        }
        async function blocked(host,port) {
          return await new Promise(resolve=>{
            const s=net.connect({host,port});s.setTimeout(500);
            s.on('connect',()=>{s.destroy();resolve(false)});
            s.on('error',()=>resolve(true));s.on('timeout',()=>{s.destroy();resolve(true)});
          });
        }
        async function raw(text) {
          return await new Promise(resolve=>{
            const s=net.connect('/relay/relay.sock',()=>s.write(text));let out='';
            s.setTimeout(1000);s.on('data',b=>out+=b);
            s.on('close',()=>resolve(out));s.on('error',()=>resolve(out));
            s.on('timeout',()=>{s.destroy();resolve(out)});
          });
        }
        (async()=>{
          const checks={};
          checks.allowed=(await request('cx/gpt-6-luna-low'))===200;
          const stream=await request('cx/gpt-6-luna-low','/v1/chat/completions',
            {stream:true,tools:[{type:'function',function:{name:'read'}}]});
          checks.streaming=stream.includes('chat.completion.chunk') && stream.includes('[DONE]');
          checks.nativeRead=stream.includes('mock-read-1') && stream.includes('/workspace/README.md');
          const shell=await request('cx/gpt-6-luna-low','/v1/chat/completions',
            {stream:true,messages:[{role:'tool',tool_call_id:'mock-read-1',content:'fixture'}],
              tools:[{type:'function',function:{name:'shell'}}]});
          checks.nativeShell=shell.includes('mock-bash-2') && shell.includes('sandbox-positive.txt') && shell.includes('test -s');
          checks.routeDenied=(await request('evil'))===403;
          checks.pathDenied=(await request('cx/gpt-6-luna-low','http://host.docker.internal/'))===400;
          checks.connectDenied=!(await raw('CONNECT host.docker.internal:80 HTTP/1.1\r\nHost: host.docker.internal\r\n\r\n')).includes('200');
          checks.framingDenied=(await raw('POST /v1/chat/completions HTTP/1.1\r\nHost: mock\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n{}')).includes('400');
          checks.noSecret=!fs.existsSync('/secret/credential');
          checks.noUpstream=!fs.existsSync('/upstream/mock.sock');
          checks.noDockerSocket=!fs.existsSync('/var/run/docker.sock');
          checks.onlyLoopback=Object.keys(require('node:os').networkInterfaces()).every(x=>x==='lo');
          checks.external=await blocked('198.51.100.1',80);
          checks.ipv6=await blocked('2001:db8::1',80);
          checks.hostName=await blocked('host.docker.internal',20128);
          checks.hostGateway=await blocked('192.168.65.254',20128);
          checks.metadata=await blocked('169.254.169.254',80);
          checks.proxy=await blocked('host.docker.internal',3128);
          checks.dns=await blocked('192.168.65.254',53);
          checks.uid=process.getuid()===65534;
          // Positive local canary proves blocked() distinguishes reachable services.
          const canary=net.createServer(s=>s.end());
          await new Promise(resolve=>canary.listen(0,'127.0.0.1',resolve));
          checks.positiveCanary=!(await blocked('127.0.0.1',canary.address().port));
          await new Promise(resolve=>canary.close(resolve));
          console.log(JSON.stringify(checks));
          if(Object.values(checks).some(x=>!x))process.exitCode=1;
        })().catch(e=>{console.error(e);process.exitCode=1});
      JS
      output = relay.command(*(relay.agent_argv + ["node", "-e", probe]))
      assert_includes output, '"allowed":true'
      assert_equal 3, relay.logs("mock").scan('"observed_route"').length
      assert_includes relay.logs("mock"), '"credential_match":true'
      assert_includes relay.logs("relay"), '"decision":"deny"'
    ensure
      relay.close
      relay.close
    end
  end
end
