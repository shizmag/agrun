# Offline mutation probe: copies repository to a temporary directory, then applies
# each one-line mutation to that copy only. Never invokes OpenCode or providers.
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
CASES = [
  ["malformed JSON accepted", "lib/agent_runtime/execution/event_stream.rb", 'error(record, "invalid_json", "Protocol record is not valid JSON", number)', "nil # mutant ignores malformed JSON", "test/execution/event_stream_test.rb"],
  ["non-object accepted", "lib/agent_runtime/execution/event_stream.rb", 'error(record, "nonobject_record", "Protocol record must be an object", number)', "nil # mutant ignores non-object", "test/execution/event_stream_test.rb"],
  ["missing finish succeeds", "lib/agent_runtime/execution/event_stream.rb", ' || record["requests"].empty?', "", "test/execution/event_stream_test.rb"],
  ["error event ignored", "lib/agent_runtime/execution/event_stream.rb", 'terminal_error = record["events"].any? { |event| event["type"] == "error" }', "terminal_error = false", "test/execution/event_stream_test.rb"],
  ["forced statuses ignored", "lib/agent_runtime/execution/event_stream.rb", "%w[timeout cancelled].include?(process_status)", "false", "test/execution/event_stream_test.rb"],
  ["truncated stdout accepted", "lib/agent_runtime/execution/event_stream.rb", " if stdout_truncated", " if false", "test/execution/event_stream_test.rb"],
  ["finish identity conflicts ignored", "lib/agent_runtime/execution/event_stream.rb", 'if prior && prior["part"]["id"] != part["id"]', "if false", "test/execution/event_stream_test.rb"],
  ["requested session mismatch ignored", "lib/agent_runtime/execution/event_stream.rb", 'if requested && record["session_id"] && requested != record["session_id"]', "if false", "test/execution/event_stream_test.rb"],
  ["claimed accounting completeness", "lib/agent_runtime/execution/event_stream.rb", '"session_reported_complete" => nil, "accounting_complete" => false', '"session_reported_complete" => nil, "accounting_complete" => true', "test/execution/event_stream_test.rb"],
  ["native cost claims provider provenance", "lib/agent_runtime/execution/event_stream.rb", '"provenance" => "opaque_cli"', '"provenance" => "provider_reported"', "test/execution/event_stream_test.rb"],
  ["duplicate requests counted twice", "lib/agent_runtime/execution/usage.rb", "observations.uniq { |record| canonical(record) }", "observations", "test/execution/usage_test.rb"],
  ["reject missing token", "lib/agent_runtime/execution/usage.rb", "value.nil? || (value.is_a?(Integer) && value >= 0)", "value.is_a?(Integer) && value >= 0", "test/execution/usage_test.rb"],
  ["missing cost is free", "lib/agent_runtime/execution/usage.rb", 'cost = record["reported_cost"]', 'cost = record["reported_cost"] || {"amount" => "0", "currency" => "USD", "provenance" => "provider_reported"}; copy["reported_cost"] = cost', "test/execution/usage_test.rb"],
  ["invalid counter accepted", "lib/agent_runtime/execution/usage.rb", "value.is_a?(Integer) && value >= 0", "value.is_a?(Integer)", "test/execution/usage_test.rb"],
  ["unknown reported cost becomes zero", "lib/agent_runtime/execution/usage.rb", 'cost = reported["total"]&.to_f', 'cost = reported["total"]&.to_f || 0.0', "test/execution/usage_test.rb"],
  ["fixture guard bypass", "lib/agent_runtime/adapters/open_code_cli.rb", "unless fixture_valid?", "if false", "test/m12_adapter_guard_test.rb"],
  ["symlink guard bypass", "lib/agent_runtime/adapters/open_code_cli.rb", "!File.symlink?(@executable)", "true", "test/m12_adapter_guard_test.rb"],
  ["digest guard bypass", "lib/agent_runtime/adapters/open_code_cli.rb", "Digest::SHA256.file(@executable).hexdigest == @fixture_sha256", "true", "test/m12_adapter_guard_test.rb"],
  ["attempt limit disabled", "lib/agent_runtime/execution/budget.rb", 'snapshot.fetch("attempts_before") >= limits.fetch("max_attempts")', "false", "test/execution/budget_test.rb"],
  ["concurrency limit disabled", "lib/agent_runtime/execution/budget.rb", 'snapshot.fetch("active_before") >= limits.fetch("max_concurrent_sessions")', "false", "test/execution/budget_test.rb"],
  ["ignore running cancellation", "lib/agent_runtime/adapters/process_runner.rb", 'forced = "cancelled" if cancellation&.cancelled?', "forced = nil", "test/m12a_process_runner_lifecycle_test.rb"],
  ["skip post-cancel TERM", "lib/agent_runtime/adapters/process_runner.rb", 'signal_group("TERM", pid)', "nil # mutant skips TERM", "test/m12a_process_runner_lifecycle_test.rb"],
  ["skip exceptional cleanup KILL", "lib/agent_runtime/adapters/process_runner.rb", "unless completed || killed", "if false # mutant skips cleanup", "test/m12a_process_runner_lifecycle_test.rb"],
  ["allow unsafe retry", "lib/agent_runtime/runtime.rb", " && result.retry_safe == true", "", "test/m01_scheduler_test.rb"],
  ["omit persisted attempt", "lib/agent_runtime/runtime.rb", "attempts << data", "nil # mutant drops attempt", "test/m12_execution_persistence_test.rb"],
  ["omit planner attempts", "lib/agent_runtime/execution/summary.rb", 'report.fetch("steps").sort.to_h do |id, step|', 'report.fetch("steps").reject { |id, _| id == "plan" }.sort.to_h do |id, step|', "test/m12_strict_solver_test.rb"],
  ["ignore budget denial", "lib/agent_runtime/adapters/open_code_cli.rb", "unless admitted", "if false", "test/m12_budget_launch_test.rb"],
  ["skip redaction", "lib/agent_runtime/execution/redaction.rb", "transform(value, literals)", "value", "test/execution/redaction_test.rb"],
  ["skip secret value replacement", "lib/agent_runtime/execution/redaction.rb", "secrets.reduce(value.dup) { |text, secret| text.gsub(secret, REPLACEMENT) }", "value.dup", "test/execution/redaction_test.rb"],
  ["profile provider substituted", "lib/agent_runtime/adapters/open_code_cli.rb", 'profile_data.fetch("provider")', '"different-provider"', "test/m12_adapter_execution_test.rb"],
  ["wrong observed model", "lib/agent_runtime/benchmarks/solvers.rb", '"requested_model" => model, "model" => nil', '"requested_model" => model, "model" => "invented"', "test/m12_experiment_execution_test.rb"],
  ["drop reconstructed requests", "lib/agent_runtime/execution/summary.rb", 'attempt.fetch("usage").fetch("requests").flat_map do |group|', "[].flat_map do |group|", "test/m12_strict_solver_test.rb"],
  ["allow pricing provider mismatch", "lib/agent_runtime/execution/usage.rb", "%w[provider model].all? { |field| record[field] == pricing[field] }", "true", "test/execution/usage_test.rb"],
  ["collapse identity scopes", "lib/agent_runtime/execution/usage.rb", '[record["identity_scope"], record["identity_kind"], record["request_id"]]', '[nil, record["identity_kind"], record["request_id"]]', "test/execution/usage_test.rb"],
  ["drop successful patch", "lib/agent_runtime/adapters/open_code_cli.rb", 'outputs = {"patch" => patch, "repository" => directory', 'outputs = {"patch" => nil, "repository" => directory', "test/m12_adapter_execution_test.rb"],
  ["estimate masquerades as provider cost", "lib/agent_runtime/execution/usage.rb", 'cost = reported["total"]&.to_f', 'cost = reported["total"]&.to_f || estimate&.fetch("amount", nil)&.to_f', "test/execution/usage_test.rb"],
  ["replace historical pricing digest", "lib/agent_runtime/execution/usage.rb", "Digest::SHA256.hexdigest(canonical(pricing))", 'Digest::SHA256.hexdigest("outdated-pricing")', "test/execution/usage_test.rb"],
  ["collapse distinct native request IDs", "lib/agent_runtime/execution/usage.rb", '[record["identity_scope"], record["identity_kind"], record["request_id"]]', '[record["identity_scope"], record["identity_kind"], "same-id"]', "test/execution/usage_test.rb"],
  ["drop partial patch on failure", "lib/agent_runtime/adapters/open_code_cli.rb", 'outputs = {"patch" => patch, "repository" => directory', 'outputs = {"patch" => (trace["outcome"] == "success" ? patch : nil), "repository" => directory', "test/m12_adapter_execution_test.rb"]
].freeze

selection = ARGV.empty? ? (1..CASES.size).to_a : ARGV.map { |value| Integer(value) }
Dir.mktmpdir("m12-mutations-") do |dir|
  %w[lib test Gemfile Gemfile.lock].each do |entry|
    path = File.join(ROOT, entry)
    FileUtils.cp_r(path, dir) if File.exist?(path)
  end
  # Explicitly use the project-local bundle; no installation or network calls.
  env = {"BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "BUNDLE_PATH" => File.join(ROOT, ".bundle/gems")}
  selection.each do |index|
    name, file, old, replacement, test = CASES.fetch(index - 1)
    path = File.join(dir, file)
    original = File.read(path)
    count = original.scan(Regexp.new(Regexp.escape(old))).size
    if count != 1
      puts "%02d | NOT_APPLIED | %s | match_count=%d" % [index, name, count]
      next
    end
    File.write(path, original.sub(old, replacement))
    output, status = Open3.capture2e(env, RbConfig.ruby, "-Itest", test, chdir: dir)
    File.write(path, original)
    report = output.lines.grep(/\d+ runs, \d+ assertions/).last&.strip || output.lines.last&.strip
    kind = if status.success?
      "SURVIVED"
    elsif output.match?(/\d+ failures?, [1-9]\d* errors?/) || !output.match?(/\d+ runs, \d+ assertions/)
      "ERROR"
    else
      "KILLED"
    end
    puts "%02d | %s | %s | %s | %s" % [index, kind, name, test, report]
  end
end
