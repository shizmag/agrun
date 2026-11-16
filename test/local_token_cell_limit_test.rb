require_relative "test_helper"
require "open3"
require "rbconfig"

class LocalTokenCellLimitTest < Minitest::Test
  def test_twelve_reservations_are_shared_by_fresh_stage_processes
    in_tmp do |root|
      config = {"cell_id" => "cell", "attempt_id" => "stage-one", "cell_counter" => File.join(root, "counter"),
                "ledger" => {"path" => File.join(root, "ledger"), "intent_digest" => "a" * 64, "total_tokens" => 100_000_000}}
      path = File.join(root, "config")
      script = File.expand_path("../scripts/local_token_ledger.rb", __dir__)
      12.times do |index|
        config["attempt_id"] = "stage-#{index / 5}"
        File.write(path, JSON.generate(config))
        _, error, status = Open3.capture3(RbConfig.ruby, script, path, stdin_data: JSON.generate("action" => "reserve", "request_id" => "request-#{index}"))
        assert status.success?, error
      end
      _, error, status = Open3.capture3(RbConfig.ruby, script, path, stdin_data: JSON.generate("action" => "reserve", "request_id" => "thirteenth"))
      refute status.success?
      assert_includes error, "cell_request_limit"
      assert_equal "12", File.read(config.fetch("cell_counter"))
    end
  end
end
