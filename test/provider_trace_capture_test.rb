require_relative "test_helper"
require "open3"
require "tmpdir"
require_relative "../lib/agent_runtime/execution/simulated_provider"

class ProviderTraceCaptureTest < Minitest::Test
  def test_actual_provider_boundary_capture_offline
    stdout, stderr, status = Open3.capture3("node", "--test", File.join(__dir__, "provider_trace_capture_test.cjs"))
    assert status.success?, "#{stdout}\n#{stderr}"
  end

  def test_explicit_simulated_trace_mount_is_private_and_usable_by_solver
    skip "explicit offline Docker opt-in required" unless ENV["AGRU_M12D_TRANSPORT_TEST"] == "1"
    [true, false].each do |raw_authorized|
      Dir.mktmpdir("agru-trace-test-") do |directory|
        provider = AgentRuntime::Execution::SimulatedProvider.new(
          trace_capture: {directory: directory, raw_authorized: raw_authorized, trace_id: "trace-test"}
        )
        begin
          provider.start(attempt_id: "attempt", cell_id: "cell", model_profile: "cx/gpt-6-luna-low")
          script = <<~JS
            const http = require('http');
            const body = JSON.stringify({model:'cx/gpt-6-luna-low', messages:[{role:'user',content:'local test'}],
              max_completion_tokens:32000,stream:true,stream_options:{include_usage:true}});
            const req = http.request({socketPath:'/relay/relay.sock',method:'POST',path:'/v1/chat/completions',
              headers:{'content-length':Buffer.byteLength(body)}}, res => res.pipe(process.stdout));
            req.on('error',()=>process.exit(1));req.end(body);
          JS
          result = AgentRuntime::Adapters::ProcessRunner.new.call(
            argv: ["docker", "run", "--rm", "--pull=never", "--network=none", "--read-only", "--cap-drop=ALL",
              "--user=65534:65534", "-v", "#{provider.relay_volume}:/relay:ro", provider.image, "node", "-e", script],
            cwd: Dir.pwd, timeout: 20
          )
          assert_equal "success", result.fetch("status"), result.inspect
          assert_includes result.fetch("stdout"), "AGRU_TRANSPORT_OK"
          records = provider.trace_capture_records
          assert_equal 1, records.size
          assert_equal "trace-test", records.first.fetch("payload").fetch("identity").fetch("trace_id")
          assert_equal true, records.first.fetch("payload").fetch("complete")
          if raw_authorized
            assert_equal "local test", records.first.fetch("payload").fetch("request_body").fetch("messages").first.fetch("content")
          else
            refute records.first.fetch("payload").key?("request_body")
            refute_includes JSON.generate(records), "local test"
          end
        ensure
          provider.close
        end
        assert_equal records, provider.trace_capture_records
      end
    end
  end

  def test_opt_in_simulator_tools_round_trip_offline
    skip "explicit offline Docker opt-in required" unless ENV["AGRU_M12D_TRANSPORT_TEST"] == "1"
    Dir.mktmpdir("agru-tool-trace-test-") do |directory|
      provider = AgentRuntime::Execution::SimulatedProvider.new(scenario: :tracing_tools,
        trace_capture: {directory: directory, raw_authorized: true, trace_id: "tools-trace"})
      begin
        provider.start(attempt_id: "tools-attempt", cell_id: "tools-cell", model_profile: "cx/gpt-6-luna-low")
        script = <<~JS
          const http = require('http'), fs = require('fs'), {spawnSync} = require('child_process');
          const messages = [{role:'user',content:'controlled tool round trip'}];
          function request() {
            return new Promise((resolve, reject) => {
              const body = JSON.stringify({model:'cx/gpt-6-luna-low',messages,
                tools:[{type:'function',function:{name:'shell',parameters:{type:'object',properties:{command:{type:'string'},workdir:{type:'string'},timeout:{type:'number'},background:{type:'boolean'}},required:['command'],additionalProperties:false}}}],
                max_completion_tokens:32000,stream:true,stream_options:{include_usage:true}});
              const req = http.request({socketPath:'/relay/relay.sock',method:'POST',path:'/v1/chat/completions',
                headers:{'content-length':Buffer.byteLength(body)}}, res => {
                  let text='';res.on('data', chunk=>text+=chunk);res.on('end',()=>{
                    if(res.statusCode!==200)return reject(Error('relay request rejected'));
                    resolve(text.split('\\n\\n').filter(frame=>frame.startsWith('data: ') && !frame.includes('[DONE]'))
                      .map(frame=>JSON.parse(frame.slice(6))));
                  });
              });req.on('error',reject);req.end(body);
            });
          }
          (async()=>{
            const first = await request();
            const delta = first[0].choices[0].delta, call = delta.tool_calls[0];
            const args = JSON.parse(call.function.arguments);
            if(call.function.name!=='shell' || JSON.stringify(Object.keys(args))!==JSON.stringify(['command']))throw Error('shell schema mismatch');
            const tool = spawnSync('/bin/sh',['-c',args.command],{cwd:'/workspace',encoding:'utf8'});
            if(tool.status!==0)throw Error('probe failed');
            messages.push({role:'assistant',content:null,tool_calls:[{id:call.id,type:call.type,function:call.function}]});
            messages.push({role:'tool',tool_call_id:call.id,content:tool.stdout + tool.stderr});
            const second = await request();
            console.log(JSON.stringify({finish:first[0].choices[0].finish_reason,stdout:tool.stdout,stderr:tool.stderr,
              probe:fs.readFileSync('/workspace/.agru-trace-probe','utf8'),second}));
          })().catch(()=>process.exit(1));
        JS
        result = AgentRuntime::Adapters::ProcessRunner.new.call(
          argv: ["docker", "run", "--rm", "--pull=never", "--network=none", "--read-only", "--cap-drop=ALL",
            "--user=65534:65534", "--tmpfs", "/workspace:rw,noexec,nosuid,mode=1777,size=1m",
            "-v", "#{provider.relay_volume}:/relay:ro", provider.image, "node", "-e", script],
          cwd: Dir.pwd, timeout: 20
        )
        assert_equal "success", result.fetch("status"), result.inspect
        round_trip = JSON.parse(result.fetch("stdout"))
        assert_equal "tool_calls", round_trip.fetch("finish")
        assert_equal "AGRU_TRACE_TOOL_OK", round_trip.fetch("stdout")
        assert_equal "AGRU_TRACE_TOOL_ERR", round_trip.fetch("stderr")
        assert_equal "traced", round_trip.fetch("probe")
        assert_equal "AGRU_TRANSPORT_OK", round_trip.fetch("second").first.fetch("choices").first.fetch("delta").fetch("content")
        records = provider.trace_capture_records
        assert_equal 2, records.size
        tool_record = records.find { |record| record.fetch("payload").fetch("reconstructed_response").fetch("choices").first.fetch("message").key?("tool_calls") }
        refute_nil tool_record
        assert_equal "shell", tool_record.fetch("payload").fetch("reconstructed_response").fetch("choices").first.fetch("message").fetch("tool_calls").first.fetch("function").fetch("name")
      ensure
        provider.close
      end
    end
  end
end
