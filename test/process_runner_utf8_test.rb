require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/process_runner"
require "rbconfig"

class ProcessRunnerUtf8Test < Minitest::Test
  def test_split_multibyte_output_is_labeled_after_capture
    result = AgentRuntime::Adapters::ProcessRunner.new.call(argv: [RbConfig.ruby, "-e", "STDOUT.binmode; [0xe2,0x82,0xac].each { |b| STDOUT.write(b.chr); STDOUT.flush; sleep 0.02 }"], cwd: Dir.pwd, timeout: 5)
    assert_equal "success", result["status"]
    assert_equal "€", result["stdout"]
    assert_equal Encoding::UTF_8, result["stdout"].encoding
    assert JSON.generate(result)
  end

  def test_invalid_output_preserves_bytes_without_replacement
    result = AgentRuntime::Adapters::ProcessRunner.new.call(argv: [RbConfig.ruby, "-e", 'STDOUT.binmode; STDOUT.write([255,226].pack("C*"))'], cwd: Dir.pwd, timeout: 5)
    assert_equal "failure", result["status"]
    assert_equal "invalid_utf8_output", result["encoding_error"]
    assert_equal "", result["stdout"]
    assert_equal [255, 226], result.fetch("binary_output_base64").fetch("stdout").unpack1("m0").bytes
    assert JSON.generate(result)
  end
end
