#!/usr/bin/env ruby
# Offline mutation probes. Mutants exist only in isolated temporary source copies.
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
MUTANTS = [
  {name: "lsp_silent_promoted_pass", source: "sandbox/m12cs3-lsp-unavailability.json", test: "test/m12cs3_lsp_installed_test.rb", from: '"classification": "N/A"', to: '"classification": "PASS"', env: {"AGRU_M12CS3_LSP_INSTALLED" => "1"}},
  {name: "lsp_wrong_source_commit", source: "sandbox/m12cs3-lsp-unavailability.json", test: "test/m12cs3_lsp_installed_test.rb", from: '"source_commit": "a6b15d33daf6ab7d35569f6d711fdb630b9f04e7"', to: '"source_commit": "0000000000000000000000000000000000000000"', env: {"AGRU_M12CS3_LSP_INSTALLED" => "1"}},
  {name: "plugin_activation_prevented", source: "test/support/m12c_plugin_sentinel/index.js", test: "test/m12cs3_plugin_calibration_test.rb", from: "  async setup(ctx) {", to: "  async setup(ctx) { return;", env: {"AGRU_M12CS3_PLUGIN_CALIBRATION" => "1"}},
  {name: "plugin_observation_only", source: "test/support/m12c_plugin_sentinel/index.js", test: "test/m12cs3_plugin_calibration_test.rb", from: '    await ctx.tool.hook("execute.before", (event) => record({phase: "execute.before", tool: event.tool}));', to: "    // hook disabled; setup remains observable", env: {"AGRU_M12CS3_PLUGIN_CALIBRATION" => "1"}},
  {name: "plugin_reenable_inherited", source: "test/m12cs3_plugin_calibration_test.rb", test: "test/m12cs3_plugin_calibration_test.rb", from: 'generated["plugins"] = ["-agru.calibration.sentinel"]', to: 'generated["plugins"] = []', env: {"AGRU_M12CS3_PLUGIN_CALIBRATION" => "1"}},
  {name: "host_fallback_executes_agent", source: "lib/agent_runtime/execution/sandbox_runner.rb", test: "test/m12cs3_host_escape_test.rb", from: "        validate_call!(argv, timeout, env)", to: "        validate_call!(argv, timeout, env)\n        system(*argv, out: File::NULL, err: File::NULL)", env: {"AGRU_S2_EXPORT_DOCKER" => "1"}},
  {name: "remove_export_digest_presence", source: "lib/agent_runtime/adapters/sandbox_open_code_cli.rb", test: "test/m12cs3_review_regression_test.rb", from: 'execution.dig("export", "digest").is_a?(String)', to: "true"},
  {name: "fixture_relabel_live_manifest", source: "lib/agent_runtime/benchmarks/experiment_manifest.rb", test: "test/m12cs3_review_regression_test.rb", from: 'models.first.dig("model_profile", "execution_kind") == "real_provider"', to: '%w[real_provider offline_fixture].include?(models.first.dig("model_profile", "execution_kind"))'},
  {name: "remove_export_manifest_integrity", source: "lib/agent_runtime/execution/sandbox_runner.rb", test: "test/m12cs2_integrated_adversarial_test.rb", from: "Digest::SHA256.hexdigest(JSON.generate(manifest))", to: '"0" * 64', env: {"AGRU_S2_EXPORT_DOCKER" => "1"}},
  {name: "freeze_allow_dirty_runtime", source: "script/m12cs3_environment_freeze.rb", test: "test/m12cs3_environment_freeze_test.rb", from: 'raise ArgumentError, "dirty repository" unless git(root, "status", "--porcelain", "--untracked-files=all").empty?', to: "nil"},
  {name: "freeze_allow_stale_digest", source: "script/m12cs3_environment_freeze.rb", test: "test/m12cs3_environment_freeze_test.rb", from: 'raise ArgumentError, "stale manifest digest" unless digest(payload) == manifest.fetch("sha256")', to: "nil"},
  {name: "freeze_allow_live_label", source: "script/m12cs3_environment_freeze.rb", test: "test/m12cs3_environment_freeze_test.rb", from: 'raise ArgumentError, "mock evidence cannot be relabeled" unless spec.fetch("evidence_kind", "installed_mock") == "installed_mock"', to: 'spec.fetch("evidence_kind", "installed_mock")'}
].freeze

Dir.mktmpdir("agru-mutations-") do |root|
  %w[lib test script sandbox].each { |dir| FileUtils.cp_r(File.join(ROOT, dir), root) }
  MUTANTS.each do |mutant|
    source = File.join(root, mutant.fetch(:source))
    original = File.binread(source)
    needle = mutant.fetch(:from)
    abort "#{mutant[:name]}: mutation anchor not unique" unless original.scan(Regexp.new(Regexp.escape(needle))).length == 1
    File.binwrite(source, original.sub(needle, mutant.fetch(:to)))
    output, status = Open3.capture2e(mutant.fetch(:env, {}), RbConfig.ruby, "-Itest", mutant.fetch(:test), chdir: root)
    puts "\n#{mutant[:name]}: #{status.success? ? "SURVIVED" : "KILLED_OR_ERROR"} (exit #{status.exitstatus})"
    puts output
    File.binwrite(source, original)
  end
end
