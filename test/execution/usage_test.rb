require_relative "../test_helper"

# B-phase red tests: do not require production implementation before its gate.
usage_path = File.expand_path("../../lib/agent_runtime/execution/usage.rb", __dir__)
require usage_path if File.file?(usage_path)

class ExecutionUsageTest < Minitest::Test
  def request(id: "request-1", tokens: {}, **changes)
    {
      "request_id" => id,
      "identity_kind" => "provider_request",
      "identity_scope" => "fixture-invocation/attempt-1",
      "provider" => "fixture-provider",
      "model" => "fixture-model",
      "tokens" => {"input" => 100, "output" => 20, "reasoning" => 0,
                   "cache_read" => 40, "cache_write" => 10}.merge(tokens),
      "input_cache_relation" => "disjoint",
      "output_reasoning_relation" => "disjoint",
      "reported_cost" => {"amount" => "0.0123", "currency" => "USD", "provenance" => "provider_reported"}
    }.merge(changes.transform_keys(&:to_s))
  end

  def pricing
    {
      "schema_version" => 1, "id" => "fixture-2026-11-15",
      "provider" => "fixture-provider", "model" => "fixture-model",
      "currency" => "USD", "source" => "https://example.invalid/prices/v1",
      "effective_date" => "2026-11-15",
      "rates_per_million" => {"input" => "2", "output" => "8", "reasoning" => "8",
                              "cache_read" => "0.2", "cache_write" => "2.5"}
    }
  end

  def normalize(requests, complete: true, pricing: nil)
    AgentRuntime::Execution::Usage.normalize(requests: requests, complete: complete, pricing: pricing)
  end

  def issue?(result, code)
    result.fetch("usage").fetch("issues").any? { |issue| issue.fetch("code") == code }
  end

  def counter(result, name)
    result.fetch("usage").fetch("tokens").fetch(name)
  end

  def test_empty_stream_is_unknown_not_free
    [true, false].each do |complete|
      result = normalize([], complete: complete, pricing: pricing)
      assert_nil result["cost"]
      assert_nil counter(result, "input")["total"]
      assert_nil counter(result, "input")["known_subtotal"]
      assert_nil result.dig("usage", "estimate", "amount")
      refute result.dig("usage", "coverage", "complete")
      assert issue?(result, "empty_stream")
    end
  end

  def test_explicit_zero_is_known
    zeros = request.fetch("tokens").transform_values { 0 }
    result = normalize([request(tokens: zeros, reported_cost: {"amount" => "0", "currency" => "USD", "provenance" => "provider_reported"})], pricing: pricing)
    assert_equal 0.0, result["cost"]
    assert_equal 0, counter(result, "input")["total"]
    assert_equal "0", result.dig("usage", "estimate", "amount")
    assert result.dig("usage", "coverage", "complete")
  end

  def test_nil_is_independent_of_known_fields
    result = normalize([request(tokens: {"cache_read" => nil}, reported_cost: nil)], pricing: pricing)
    assert_nil result["cost"]
    assert_nil counter(result, "cache_read")["total"]
    assert_equal 100, counter(result, "input")["total"]
    assert_nil result.dig("usage", "estimate", "amount")
    refute result.dig("usage", "coverage", "complete")
  end

  def test_reported_cost_does_not_require_known_tokens
    tokens = request.fetch("tokens").transform_values { nil }
    result = normalize([request(tokens: tokens)])
    assert_equal 0.0123, result["cost"]
    assert_equal "0.0123", result.dig("usage", "reported_cost", "total")
    assert_nil counter(result, "input")["total"]
    assert_nil result.dig("usage", "estimate")
  end

  def test_distinct_identities_with_equal_values_both_count
    result = normalize([request(id: "a"), request(id: "b")])
    assert_equal 200, counter(result, "input")["total"]
    assert_equal "0.0246", result.dig("usage", "reported_cost", "total")
    assert_equal 2, result.dig("usage", "coverage", "accepted_requests")
  end

  def test_identical_events_deduplicate_independently_of_hash_order
    original = request
    reordered = original.to_a.reverse.to_h
    reordered["tokens"] = original.fetch("tokens").to_a.reverse.to_h
    result = normalize([original, reordered])
    assert_equal 100, counter(result, "input")["total"]
    assert_equal 1, result.dig("usage", "coverage", "duplicate_observations")
    assert_equal 1, result.dig("usage", "coverage", "accepted_requests")
    assert_equal 1, result.dig("usage", "requests").first.fetch("observations").length
  end

  def test_conflicting_variants_are_not_merged_or_chosen_by_event_order
    [request(tokens: {"input" => 101}), request(model: "other"),
      request(reported_cost: nil), request(tokens: {"output" => nil})].each do |variant|
      records = [request, variant, request(id: "unrelated")]
      result = normalize(records, pricing: pricing)
      assert_equal result, normalize(records.reverse, pricing: pricing)
      assert_nil counter(result, "input")["total"]
      assert_equal 100, counter(result, "input")["known_subtotal"]
      assert_nil result["cost"]
      assert_equal "0.0123", result.dig("usage", "reported_cost", "known_subtotal")
      assert_nil result.dig("usage", "estimate", "amount")
      assert issue?(result, "conflicting_request")
      group = result.dig("usage", "requests").find { |row| row["request_id"] == "request-1" }
      assert_equal 2, group.fetch("observations").length
    end
  end

  def test_unidentified_equal_observations_are_not_assumed_distinct_or_duplicates
    result = normalize([request(id: nil), request(id: nil)])
    assert_nil counter(result, "input")["known_subtotal"]
    assert_equal 2, result.dig("usage", "coverage", "unidentified_observations")
    assert_equal 0, result.dig("usage", "coverage", "duplicate_observations")
    assert_nil result["cost"]
    assert issue?(result, "unidentified_request")
  end

  def test_partial_stream_preserves_subtotals_not_complete_provider_or_estimated_cost
    result = normalize([request], complete: false, pricing: pricing)
    assert_nil result["cost"]
    assert_nil counter(result, "input")["total"]
    assert_equal 100, counter(result, "input")["known_subtotal"]
    assert_equal "0.0123", result.dig("usage", "reported_cost", "known_subtotal")
    assert_equal "0.000393", result.dig("usage", "estimate", "known_subtotal")
    assert_nil result.dig("usage", "estimate", "amount")
    assert issue?(result, "incomplete_stream")
  end

  def test_cache_disjoint_and_subset_have_different_billing_without_changing_raw_counts
    disjoint = normalize([request], pricing: pricing)
    subset = normalize([request(input_cache_relation: "subset")], pricing: pricing)
    assert_equal "0.000393", disjoint.dig("usage", "estimate", "amount")
    assert_equal "0.000293", subset.dig("usage", "estimate", "amount")
    assert_equal counter(disjoint, "input"), counter(subset, "input")
    assert_equal 0.0123, subset["cost"]
  end

  def test_unknown_cache_relation_never_guesses_native_input_semantics
    result = normalize([request(input_cache_relation: "unknown")], pricing: pricing)
    assert_equal 100, counter(result, "input")["total"]
    assert_nil result.dig("usage", "estimate", "amount")
    assert issue?(result, "unknown_cache_relation")
  end

  def test_reasoning_is_additional_or_overlapping_only_as_declared
    disjoint = normalize([request(tokens: {"reasoning" => 5})], pricing: pricing)
    subset = normalize([request(tokens: {"reasoning" => 5}, output_reasoning_relation: "subset")], pricing: pricing)
    unknown = normalize([request(output_reasoning_relation: "unknown")], pricing: pricing)
    assert_equal "0.000433", disjoint.dig("usage", "estimate", "amount")
    assert_equal "0.000393", subset.dig("usage", "estimate", "amount")
    assert_nil unknown.dig("usage", "estimate", "amount")
    assert issue?(unknown, "unknown_reasoning_relation")
  end

  def test_impossible_subsets_are_not_priced
    [request(tokens: {"cache_read" => 91}, input_cache_relation: "subset"),
      request(tokens: {"reasoning" => 21}, output_reasoning_relation: "subset")].each do |record|
      result = normalize([record], pricing: pricing)
      assert_nil result.dig("usage", "estimate", "amount")
      assert issue?(result, "inconsistent_subset")
      assert_equal 0.0123, result["cost"]
    end
  end

  def test_missing_cache_or_reasoning_is_not_implicitly_zero_priced
    %w[cache_read cache_write reasoning].each do |field|
      result = normalize([request(tokens: {field => nil})], pricing: pricing)
      assert_nil result.dig("usage", "estimate", "amount")
      assert_nil counter(result, field)["total"]
    end
  end

  def test_estimate_never_fills_missing_reported_cost
    result = normalize([request(reported_cost: nil)], pricing: pricing)
    assert_equal "0.000393", result.dig("usage", "estimate", "amount")
    assert_equal "estimate", result.dig("usage", "estimate", "kind")
    assert_nil result["cost"]
    assert_nil result.dig("usage", "reported_cost", "total")
  end

  def test_pricing_requires_actual_matching_provider_and_model
    [request(model: nil), request(provider: nil), request(model: "other"), request(provider: "other")].each do |record|
      result = normalize([record], pricing: pricing)
      assert_nil result.dig("usage", "estimate", "amount")
      assert issue?(result, "pricing_identity_mismatch")
      assert_equal 0.0123, result["cost"]
    end
    mixed = normalize([request, request(id: "other", model: "other")], pricing: pricing)
    assert_nil mixed.dig("usage", "estimate", "amount")
    assert_equal "0.000393", mixed.dig("usage", "estimate", "known_subtotal")
    assert_equal 1, mixed.dig("usage", "estimate", "known_requests")
  end

  def test_pinned_price_revision_and_provenance_change_digest
    original = normalize([request], pricing: pricing)
    digest = original.dig("usage", "estimate", "pricing_digest")
    assert_equal AgentRuntime::IR.digest(pricing), digest
    assert_equal pricing, original.dig("usage", "estimate", "pricing")
    %w[id source effective_date].each do |field|
      revised = pricing.merge(field => ((field == "effective_date") ? "2026-11-16" : "revision-2"))
      refute_equal digest, normalize([request], pricing: revised).dig("usage", "estimate", "pricing_digest")
    end
    revised = pricing
    revised.fetch("rates_per_million")["input"] = "3"
    result = normalize([request], pricing: revised)
    refute_equal digest, result.dig("usage", "estimate", "pricing_digest")
    assert_equal "0.000493", result.dig("usage", "estimate", "amount")
    assert_equal "0.000393", original.dig("usage", "estimate", "amount")
  end

  def test_invalid_or_unprovenanced_pricing_raises_without_defaults
    invalid = [pricing.except("source"), pricing.merge("source" => ""),
      pricing.merge("schema_version" => 2), pricing.merge("effective_date" => "2026-02-30")]
    [nil, "-1", "not-a-decimal", "NaN", "Infinity", 2.0, true].each do |rate|
      table = pricing
      table.fetch("rates_per_million")["input"] = rate
      invalid << table
    end
    missing_rate = pricing
    missing_rate.fetch("rates_per_million").delete("cache_write")
    invalid << missing_rate
    invalid.each { |table| assert_raises(ArgumentError) { normalize([request], pricing: table) } }
  end

  def test_invalid_observed_counts_are_unknown_and_json_safe
    [-1, 1.5, true, "100", Float::NAN, Float::INFINITY].each do |count|
      result = normalize([request(tokens: {"input" => count})], pricing: pricing)
      assert_nil counter(result, "input")["total"]
      assert_equal 20, counter(result, "output")["total"]
      assert_nil result.dig("usage", "requests", 0, "observations", 0, "tokens", "input")
      assert issue?(result, "invalid_token_count")
      assert_equal result, JSON.parse(JSON.generate(result))
    end
  end

  def test_invalid_reported_cost_does_not_destroy_tokens
    ["-1", "not-a-decimal", "NaN", "Infinity", 0.1, true].each do |amount|
      result = normalize([request(reported_cost: {"amount" => amount, "currency" => "USD", "provenance" => "provider_reported"})])
      assert_nil result["cost"]
      assert_equal 100, counter(result, "input")["total"]
      assert issue?(result, "invalid_reported_cost")
      assert_equal result, JSON.parse(JSON.generate(result))
    end
    result = normalize([request(reported_cost: {"amount" => "1", "currency" => "", "provenance" => "provider_reported"})])
    assert_nil result["cost"]
    assert issue?(result, "invalid_reported_cost")
  end

  def test_mixed_currencies_are_not_summed_or_converted
    result = normalize([request, request(id: "eur", reported_cost: {"amount" => "1", "currency" => "EUR", "provenance" => "provider_reported"})])
    assert_nil result["cost"]
    %w[total known_subtotal currency].each { |field| assert_nil result.dig("usage", "reported_cost", field) }
    assert issue?(result, "mixed_currency")
  end

  def test_exact_decimal_arithmetic_and_unrepresentable_legacy_float
    table = pricing
    table.fetch("rates_per_million").transform_values! { "0.000000000001" }
    record = request(tokens: {"input" => 1_000_000_000_000_000_001, "output" => 0,
                              "cache_read" => 0, "cache_write" => 0})
    result = normalize([record], pricing: table)
    assert_equal "1.000000000000000001", result.dig("usage", "estimate", "amount")
    huge = "1" + "0" * 400
    result = normalize([request(reported_cost: {"amount" => huge, "currency" => "USD", "provenance" => "provider_reported"})])
    assert_equal huge, result.dig("usage", "reported_cost", "total")
    assert_nil result["cost"]
  end

  def test_all_roles_and_retries_are_counted_when_caller_supplies_distinct_scoped_identities
    # Canonical fixture only: role selection/retry policy and native mapping are
    # adapter-owned. Same native ID is scoped by role/attempt before this call.
    ids = %w[architect/attempt-1/native-1 solver/attempt-1/native-1
      reviewer/attempt-1/native-1 solver/attempt-2/native-1]
    records = ids.map { |id| request(id: id) }
    result = normalize(records + [records.last], pricing: pricing)
    assert_equal 400, counter(result, "input")["total"]
    assert_equal "0.0492", result.dig("usage", "reported_cost", "total")
    assert_equal "0.001572", result.dig("usage", "estimate", "amount")
    assert_equal 4, result.dig("usage", "coverage", "accepted_requests")
    assert_equal 1, result.dig("usage", "coverage", "duplicate_observations")
  end

  def test_normalization_is_nonmutating_deterministic_and_json_compatible
    records, table = [request], pricing
    before = JSON.generate([records, table])
    result = normalize(records, pricing: table)
    assert_equal 1, result.dig("usage", "schema_version")
    assert_equal result, normalize(records, pricing: table)
    assert_equal before, JSON.generate([records, table])
    assert_equal result, JSON.parse(JSON.generate(result))
  end

  def test_root_step_observations_are_not_complete_provider_requests
    record = request(identity_kind: "root_step_observation", identity_scope: "run/solver/attempt-1",
      reported_cost: nil)
    result = normalize([record], complete: false, pricing: pricing)
    assert_nil result["cost"]
    assert_nil counter(result, "input")["total"]
    assert_equal 100, counter(result, "input")["known_subtotal"]
    assert_equal "root_step_observation", result.dig("usage", "coverage", "identity_kind")
    refute result.dig("usage", "coverage", "stream_complete")
    refute result.dig("usage", "coverage", "complete")
    assert_nil result.dig("usage", "estimate", "amount")
  end

  def test_identity_is_scoped_to_attempt_not_bare_native_id
    records = [request(identity_scope: "attempt-1"), request(identity_scope: "attempt-2")]
    result = normalize(records)
    assert_equal 200, counter(result, "input")["total"]
    assert_equal 2, result.dig("usage", "coverage", "accepted_requests")
  end

  def test_unprovenanced_cli_cost_is_not_a_provider_charge
    [nil, "cli_reported", "model_estimate"].each do |provenance|
      cost = {"amount" => "0.0123", "currency" => "USD", "provenance" => provenance}
      cost.delete("provenance") if provenance.nil?
      result = normalize([request(reported_cost: cost)])
      assert_nil result["cost"]
      assert_nil result.dig("usage", "reported_cost", "total")
      assert issue?(result, "invalid_reported_cost")
    end
  end
end
