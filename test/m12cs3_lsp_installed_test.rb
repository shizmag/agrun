require_relative "test_helper"
require_relative "support/m12c_relay_docker"

class M12cs3LspInstalledTest < Minitest::Test
  IMAGE = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1".freeze
  BINARY = "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0".freeze

  def test_unavailable_lsp_known_version_contract
    skip "set AGRU_M12CS3_LSP_INSTALLED=1 for offline Docker calibration" unless ENV["AGRU_M12CS3_LSP_INSTALLED"] == "1"
    manifest = JSON.parse(File.read(File.expand_path("../sandbox/m12cs3-lsp-unavailability.json", __dir__)))
    assert_equal "N/A", manifest.fetch("classification")
    assert_equal %w[LSP01 LSP02 LSP03 LSP04 LSP05], manifest.fetch("cases")
    assert_equal IMAGE, manifest.fetch("image")
    assert_equal BINARY, manifest.fetch("binary_sha256")
    assert_equal false, manifest.fetch("containment_credit")
    assert_equal "a6b15d33daf6ab7d35569f6d711fdb630b9f04e7", manifest.fetch("source_commit")
    manifest.fetch("source").each do |source|
      assert_match(/\A[0-9a-f]{64}\z/, source.fetch("sha256"))
      assert_operator source.fetch("line"), :>, 0
    end
    observations = [true, false].map { |enabled| observe(enabled) }
    observations.each do |observation|
      assert_equal ["read", "write"], observation.fetch(:tools).map { |tool| tool.fetch("tool") }
      assert observation.fetch(:tools).all? { |tool| tool.dig("state", "status") == "completed" }
    end
    observations.each { |observation| assert_empty observation.fetch(:records), "known-version unavailability changed; recalibrate, do not infer suppression" }
  end

  private

  def observe(enabled)
    in_tmp do |workspace|
      File.chmod(0o777, workspace)
      %w[m12cs3_lsp_server.cjs m12cs3_lsp_mock.cjs].each do |name|
        FileUtils.cp(File.expand_path("support/#{name}", __dir__), workspace)
      end
      File.write(File.join(workspace, "input.agru"), "AGRU_DOCUMENT\n")
      config = {"model" => "mock/lsp-fixture", "plugins" => [], "mcp" => {},
                "lsp" => enabled ? {"calibration" => {"command" => ["node", "/workspace/m12cs3_lsp_server.cjs"],
                                                      "extensions" => [".agru"], "env" => {"AGRU_LSP_TRANSCRIPT" => "/workspace/lsp.jsonl"}}} : false,
                "providers" => {"mock" => {"package" => "@opencode/ai/providers/openai-compatible",
                                           "settings" => {"transport" => "http", "baseURL" => "http://127.0.0.1:18080/v1", "apiKey" => "mock-only"},
                                           "models" => {"lsp-fixture" => {"name" => "Mock"}}}}}
      File.write(File.join(workspace, "opencode.json"), JSON.generate(config))
      script = <<~SH
         printf '%s  /usr/local/bin/opencode\n' '#{BINARY}' | sha256sum -c - >&2 || exit 72
         test "$(/usr/local/bin/opencode --version)" = 'opencode v2.3.0' || exit 73
         node -e 'const s=require("fs").readFileSync("/usr/local/bin/opencode").toString(); if (!s.includes("Config.LSP.Server") || s.includes("textDocument")) process.exit(74)' || exit 74
        node /workspace/m12cs3_lsp_mock.cjs &
        mock=$!
        trap 'kill $mock 2>/dev/null || true' EXIT
        /usr/local/bin/opencode run --standalone --auto --format json --model mock/lsp-fixture 'Read input.agru'
      SH
      output = M12cRelayDocker.new.command("run", "--rm", "--pull=never", "--network=none",
        "-v", "#{workspace}:/workspace", "-w", "/workspace",
        "-e", "OPENCODE_DISABLE_AUTOUPDATE=1", "-e", "OPENCODE_DISABLE_MODELS_FETCH=1",
        "--entrypoint", "sh", IMAGE, "-c", script)
      events = output.lines.filter_map do |line|
        JSON.parse(line) if line.start_with?("{")
      end
      transcript = File.join(workspace, "lsp.jsonl")
      {tools: events.select { |event| event["type"] == "tool_use" }.map { |event| event.fetch("part") },
       records: File.exist?(transcript) ? File.readlines(transcript).map { |line| JSON.parse(line) } : []}
    end
  end
end
