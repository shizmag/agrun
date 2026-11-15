require_relative "../test_helper"
require_relative "../../lib/agent_runtime/execution/redaction"

class RedactionTest < Minitest::Test
  def redact(value, **options)
    AgentRuntime::Execution::Redaction.redact(value, **options)
  end

  def test_sensitive_keys_are_redacted_recursively_without_mutation
    original = {"env" => {"API_KEY" => "synthetic-key", "PATH" => "/bin"},
                "events" => [{"authorization" => "Bearer synthetic-token", "tokens" => {"input" => 10}}],
                "password" => nil}
    original.freeze
    result = redact(original)
    assert_equal "[REDACTED]", result.fetch("env").fetch("API_KEY")
    assert_equal "/bin", result.fetch("env").fetch("PATH")
    assert_equal "[REDACTED]", result.fetch("events").first.fetch("authorization")
    assert_equal({"input" => 10}, result.fetch("events").first.fetch("tokens"))
    assert_equal "[REDACTED]", result.fetch("password")
    assert_equal "synthetic-key", original.fetch("env").fetch("API_KEY")
    refute_same original.fetch("env"), result.fetch("env")
  end

  def test_explicit_secret_literals_are_replaced_in_any_string_including_keys
    result = redact({"stdout" => "prefix synthetic-key suffix", "synthetic-key" => ["synthetic-key"]}, secrets: ["synthetic-key", "", nil])
    assert_equal "prefix [REDACTED] suffix", result.fetch("stdout")
    assert_equal ["[REDACTED]"], result.fetch("[REDACTED]")
  end

  def test_json_lines_remain_parseable_with_sensitive_values_redacted
    lines = [{"type" => "future", "data" => {"api_key" => "synthetic-key", "count" => 3}},
      {"type" => "text", "text" => "hello"}].map { |value| JSON.generate(value) }.join("\n") + "\n"
    result = redact(lines)
    parsed = result.lines.map { |line| JSON.parse(line) }
    assert_equal "[REDACTED]", parsed.first.fetch("data").fetch("api_key")
    assert_equal 3, parsed.first.fetch("data").fetch("count")
    assert_equal "hello", parsed.last.fetch("text")
    assert result.end_with?("\n")
    refute_includes result, "synthetic-key"
  end

  def test_assignment_shaped_secrets_in_plain_output_are_redacted
    result = redact("API_KEY=synthetic-key\npassword: synthetic-password\nAuthorization: Bearer synthetic-token\nOK=value\n")
    refute_includes result, "synthetic-key"
    refute_includes result, "synthetic-password"
    refute_includes result, "synthetic-token"
    assert_includes result, "OK=value"
  end

  def test_longest_secret_first_and_idempotent
    result = redact("long-secret short", secrets: ["long", "long-secret", "short"])
    assert_equal "[REDACTED] [REDACTED]", result
    assert_equal result, redact(result, secrets: ["long-secret", "short"])
  end

  def test_preserves_plain_values_and_returns_detached_strings
    source = {"count" => 7, "flag" => true, "nil" => nil, "text" => "ordinary"}
    result = redact(source)
    assert_equal source, result
    refute_same source.fetch("text"), result.fetch("text")
  end

  def test_sensitive_environment_values_can_be_collected_by_caller_for_raw_output
    config = {"env" => {"API_KEY" => "synthetic-key"}, "prompt" => "use synthetic-key"}
    secrets = config.fetch("env").select { |key, _| AgentRuntime::Execution::Redaction::SENSITIVE_KEY.match?(key) }.values
    refute_includes JSON.generate(redact(config, secrets: secrets)), "synthetic-key"
    refute_includes redact("tool echoed synthetic-key", secrets: secrets), "synthetic-key"
  end

  def test_only_allowlisted_numeric_accounting_shapes_survive_token_key_redaction
    native = {"input" => 10, "output" => 3, "reasoning" => nil, "cache" => {"read" => 4, "write" => 1}}
    canonical = {"input" => 10, "output" => nil, "reasoning" => 2, "cache_read" => 4, "cache_write" => 1}
    assert_equal native, redact({"tokens" => native}).fetch("tokens")
    assert_equal canonical, redact({"tokens" => canonical}).fetch("tokens")
    assert_equal({"input_tokens" => 10, "output_tokens" => nil}, redact({"input_tokens" => 10, "output_tokens" => nil}))
    [{"secret" => 10}, {"input" => "credential"}, {"cache" => {"read" => "secret"}},
      {"input" => 1, "authorization" => "secret"}, [1, 2], "secret", 7, nil].each do |unsafe|
      assert_equal "[REDACTED]", redact({"tokens" => unsafe}).fetch("tokens"), unsafe.inspect
    end
    assert_equal "[REDACTED]", redact({"token" => 123}).fetch("token")
    assert_equal "[REDACTED]", redact({"input_tokens" => "secret"}).fetch("input_tokens")
    assert_equal "[REDACTED]", redact({"api_tokens" => [1]}).fetch("api_tokens")
  end

  def test_raw_json_usage_counters_remain_reconstructable_but_credentials_do_not
    raw = JSON.generate({"type" => "step_finish", "part" => {"tokens" => {"input" => 10, "cache" => {"read" => 2}}, "API_KEY" => "secret"}})
    part = JSON.parse(redact(raw)).fetch("part")
    assert_equal({"input" => 10, "cache" => {"read" => 2}}, part.fetch("tokens"))
    assert_equal "[REDACTED]", part.fetch("API_KEY")
  end
end
