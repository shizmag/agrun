require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/simulated_provider"

class SimulatedProviderTest < Minitest::Test
  def test_rejects_unknown_models_before_starting_docker
    provider = AgentRuntime::Execution::SimulatedProvider.new
    assert_raises(ArgumentError) { provider.start(attempt_id: "a", cell_id: "c", model_profile: "other") }
  ensure
    provider&.close
  end

  def test_offline_https_exchange_binds_caller_identity
    skip "explicit offline Docker opt-in required" unless ENV["AGRU_M12D_TRANSPORT_TEST"] == "1"
    provider = AgentRuntime::Execution::SimulatedProvider.new
    provider.start(attempt_id: "caller-attempt", cell_id: "caller-cell", model_profile: "cx/gpt-6-luna-low")
    script = <<~JS
      const http=require('http');
      const body=JSON.stringify({model:'cx/gpt-6-luna-low',messages:[{role:'user',content:'offline'}],
        max_completion_tokens:32000,stream:true,stream_options:{include_usage:true}});
      const req=http.request({socketPath:'/relay/relay.sock',method:'POST',path:'/v1/chat/completions',
        headers:{'content-length':Buffer.byteLength(body)}},res=>{res.pipe(process.stdout);});
      req.on('error',()=>process.exit(1));req.end(body);
    JS
    result = AgentRuntime::Adapters::ProcessRunner.new.call(
      argv: ["docker", "run", "--rm", "--pull=never", "--network=none", "--read-only", "--cap-drop=ALL",
        "--user=65534:65534", "-v", "#{provider.relay_volume}:/relay:ro", provider.image, "node", "-e", script],
      cwd: Dir.pwd, timeout: 20
    )
    assert_equal "success", result.fetch("status")
    assert_includes result.fetch("stdout"), "AGRU_TRANSPORT_OK"
    record = provider.logs.lines.filter_map { |line| JSON.parse(line) if line.start_with?("{") }.last
    assert_equal "caller-attempt", record.fetch("attempt_id")
    assert_equal "caller-cell", record.fetch("cell_id")
    assert_equal "simulated-not-attested", record.fetch("response_model")
    assert_equal 12, record.fetch("usage").fetch("prompt_tokens")
  ensure
    provider&.close
  end
end
