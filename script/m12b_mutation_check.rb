# Offline, isolated mutation probes; never launches a provider.
require "tmpdir"
require "fileutils"
require "open3"

ROOT = File.expand_path("..", __dir__)
MUTATIONS = {
  5 => ["lib/agent_runtime/execution/live_authorization.rb", 'raise ArgumentError, "authorization_expired" if now >= @data.fetch("expires_at")', "nil # mutation expiry", "test/m12b_authorization_test.rb"],
  6 => ["lib/agent_runtime/execution/budget.rb", "elsif @attempts.key?(key)", "elsif false # mutation duplicate admission", "test/m12b_adversarial_test.rb"],
  1 => ["lib/agent_runtime/adapters/open_code_cli.rb", "@live && @authorization.instance_of?(Execution::LiveAuthorization) && @authorization.equal?(authorization)", "@live && @authorization.equal?(authorization) # mutant bypass concrete authorization", "test/m12b_adversarial_test.rb"],
  2 => ["lib/agent_runtime/execution/live_authorization.rb", "unless scope == @scope", "unless true # mutant reusable scope", "test/m12b_authorization_test.rb"],
  3 => ["lib/agent_runtime/execution/opencode_launch.rb", 'MODEL = "omniroute/cx/gpt-6-luna-low".freeze', 'MODEL = "omniroute/wrong-model".freeze', "test/opencode_launch_test.rb"],
  4 => ["lib/agent_runtime/execution/opencode_launch.rb", 'ENDPOINT = "http://localhost:20128/v1".freeze', 'ENDPOINT = "http://localhost:9999/v1".freeze', "test/m12b_adversarial_test.rb"],
  8 => ["lib/agent_runtime/adapters/open_code_cli.rb", "unless admitted", "unless true # mutant denial proceeds", "test/m12b_adversarial_test.rb"],
  9 => ["lib/agent_runtime/execution/summary.rb", '"title_usage" => "unknown"', '"title_usage" => "complete"', "test/m12b_reporting_test.rb"],
  10 => ["lib/agent_runtime/execution/summary.rb", '"compaction_usage" => "unknown"', '"compaction_usage" => "complete"', "test/m12b_reporting_test.rb"],
  11 => ["lib/agent_runtime/execution/summary.rb", '"child_usage" => "unknown"', '"child_usage" => "complete"', "test/m12b_reporting_test.rb"],
  12 => ["lib/agent_runtime/execution/summary.rb", '"provider_retries" => "unknown"', '"provider_retries" => "complete"', "test/m12b_reporting_test.rb"],
  13 => ["lib/agent_runtime/execution/usage.rb", "observations.uniq { |record| canonical(record) }", "observations # mutant no dedup", "test/execution/usage_test.rb"],
  14 => ["lib/agent_runtime/execution/usage.rb", "subtotal = values.empty? ? nil : values.sum", "subtotal = values.empty? ? 0 : values.sum", "test/execution/usage_test.rb"],
  15 => ["lib/agent_runtime/execution/summary.rb", '"actual_charge_status" => "unknown", "actual_charge" => nil', '"actual_charge_status" => "known", "actual_charge" => normalized.dig("usage", "estimate")', "test/m12b_reporting_test.rb"],
  16 => ["lib/agent_runtime/adapters/open_code_cli.rb", "unless mismatches.empty?", "if false # mutant accept model mismatch", "test/m12b_live_execution_test.rb"],
  18 => ["lib/agent_runtime/adapters/open_code_cli.rb", 'usage: normalized["usage"], cost: nil, logs: {"execution" => trace}, session_id: trace["session_id"], retry_safe: false)', 'usage: normalized["usage"], cost: nil, logs: {"execution" => trace}, session_id: trace["session_id"], retry_safe: true)', "test/m12b_live_execution_test.rb"],
  19 => ["lib/agent_runtime/adapters/open_code_cli.rb", "if artifact_error", "if false # mutant ignore artifact failure", "test/m12b_live_execution_test.rb"],
  20 => ["lib/agent_runtime/benchmarks/adapters/nl2repo.rb", 'File.write(instruction_path, public_task.fetch("instruction"))', 'File.write(instruction_path, public_task.fetch("instruction")); File.write(File.join(destination, "hidden_test.rb"), "hidden procedure leaked")', "test/m12b_adversarial_test.rb"],
  21 => ["lib/agent_runtime/execution/opencode_launch.rb", "unless File.file?(@executable) && Digest::SHA256.file(@executable).hexdigest == @executable_sha256", "unless true # mutant ignore executable change", "test/opencode_launch_test.rb"],
  24 => ["lib/agent_runtime/execution/summary.rb", '"cleanup" => cleanup_projection(cleanup),', '"cleanup" => nil,', "test/m12b_reporting_test.rb"],
  17 => ["lib/agent_runtime/execution/event_stream.rb", "%w[timeout cancelled].include?(process_status)", "%w[timeout].include?(process_status)", "test/execution/event_stream_test.rb"],
  22 => ["lib/agent_runtime/execution/summary.rb", "[field, values.one? ? values.first : nil]", "[field, values.one? ? values.first : profile[field]]", "test/m12b_reporting_test.rb"],
  23 => ["lib/agent_runtime/execution/event_stream.rb", '"cache_read" => cache["read"], "cache_write" => cache["write"]', '"cache_read" => nil, "cache_write" => nil', "test/m12b_adversarial_test.rb"]
}.freeze

Dir.mktmpdir("m12b-mutations-") do |dir|
  %w[lib test benchmarks Gemfile Gemfile.lock].each { |name| FileUtils.cp_r(File.join(ROOT, name), dir) }
  File.symlink(File.join(ROOT, ".bundle"), File.join(dir, ".bundle"))
  MUTATIONS.each do |id, (path, original, replacement, test)|
    file = File.join(dir, path)
    source = File.binread(file)
    count = source.scan(Regexp.new(Regexp.escape(original))).length
    unless count == 1
      puts "#{id}: INVALID exact source match count=#{count}"
      next
    end
    begin
      File.binwrite(file, source.sub(original, replacement))
      output, status = Open3.capture2e({"BUNDLE_GEMFILE" => File.join(dir, "Gemfile")}, RbConfig.ruby,
        "-S", "bundle", "exec", "ruby", "-Itest", test, chdir: dir)
      result = if status.success?
        "SURVIVED"
      elsif output.match?(/\d+ runs, \d+ assertions, [1-9]\d* failures, 0 errors/)
        "KILLED"
      else
        "INVALID (setup/error)"
      end
      puts "#{id}: #{result} (#{test})\n#{output.lines.grep(/Failure:|Error:|runs,|Expected:|Actual:/).join}"
    ensure
      File.binwrite(file, source)
    end
  end
end
