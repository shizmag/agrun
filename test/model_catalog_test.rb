require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/model_catalog"

class ModelCatalogTest < Minitest::Test
  def data
    {"revision" => "fixture-v1", "models" => {"base" => {}},
     "variants" => {"low" => {"model" => "base", "parameters" => {"reasoning_effort" => "low"}, "pricing" => "shared"},
                    "other" => {"model" => "base", "parameters" => {}, "pricing" => "shared"}},
     "routes" => {"route" => {"provider" => "fixture", "endpoint" => "http://localhost/v1", "wire_id" => "exact-low", "variant" => "low", "gateway_model" => "base",
                              "accounting" => {"input_includes_cached" => true, "output_includes_reasoning" => true, "provenance" => "synthetic"}}},
     "pricing" => {"shared" => {"revision" => "tariff-v1", "provenance" => "synthetic test only", "currency" => "TEST", "per_tokens" => 1,
                                "rates" => {"input" => "2", "cached_input" => "1", "output" => "3", "reasoning" => "3"}}}}
  end

  def evidence(catalog, snapshot)
    catalog.attribute(snapshot, gateway_model: "base", gateway_provider: "fixture", gateway_endpoint: "http://localhost/v1")
  end

  def test_explicit_resolution_inherits_price_without_changing_wire_identity
    catalog = AgentRuntime::Execution::ModelCatalog.new(data)
    resolved = catalog.resolve("route")
    assert_equal "exact-low", resolved.fetch("route").fetch("wire_id")
    assert_equal "shared", resolved.fetch("variant").fetch("pricing")
    assert resolved.frozen?
    assert_equal "match", catalog.attribute(resolved, gateway_model: "base", gateway_provider: "fixture", gateway_endpoint: "http://localhost/v1").fetch("gateway_status")
    assert_equal "unknown", catalog.attribute(resolved, gateway_model: "base").fetch("gateway_status")
    assert_nil catalog.attribute(resolved, gateway_model: "base")["served"]
    assert_equal "mismatch", catalog.attribute(resolved, gateway_model: "wrong").fetch("gateway_status")
    assert_raises(ArgumentError) { catalog.resolve("unknown") }
  end

  def test_catalog_revision_and_unknown_references
    a = AgentRuntime::Execution::ModelCatalog.new(data).resolve("route")
    b = AgentRuntime::Execution::ModelCatalog.new(data.merge("revision" => "v2")).resolve("route")
    refute_equal a, b
    changed = data
    changed["routes"]["route"]["variant"] = "missing"
    assert_raises(ArgumentError) { AgentRuntime::Execution::ModelCatalog.new(changed).resolve("route") }
    changed = data
    changed["pricing"].clear
    assert_raises(ArgumentError) { AgentRuntime::Execution::ModelCatalog.new(changed).resolve("route") }
    changed["variants"]["low"]["pricing"] = nil
    assert_nil AgentRuntime::Execution::ModelCatalog.new(changed).resolve("route")["pricing"]
  end

  def test_inclusive_accounting_and_missing_usage
    catalog = AgentRuntime::Execution::ModelCatalog.new(data)
    resolved = catalog.resolve("route")
    usage = {"input" => 10, "cached_input" => 4, "output" => 5, "reasoning" => 2}
    assert_equal "31/1", catalog.cost(resolved, attribution: evidence(catalog, resolved), usage: usage).fetch("amount")
    assert_nil catalog.cost(resolved, attribution: evidence(catalog, resolved), usage: usage.except("cached_input"))["amount"]
    unverified = data
    unverified["routes"]["route"].delete("accounting")
    assert_nil catalog.cost(AgentRuntime::Execution::ModelCatalog.new(unverified).resolve("route"), usage: usage)["amount"]
    assert_equal resolved, JSON.parse(JSON.generate(resolved))
  end

  def test_variants_and_snapshot_are_distinct_and_immutable
    source = data
    source["routes"]["second"] = source["routes"]["route"].merge("variant" => "other", "wire_id" => "exact#other")
    catalog = AgentRuntime::Execution::ModelCatalog.new(source)
    a = catalog.resolve("route")
    b = catalog.resolve("second")
    refute_equal a["variant_id"], b["variant_id"]
    assert_equal a["pricing"], b["pricing"]
    source["pricing"]["shared"]["rates"]["input"] = "999"
    assert_equal "2", a["pricing"]["rates"]["input"]
    assert_raises(FrozenError) { a["route"]["wire_id"].replace("wrong") }
  end

  def test_bad_counts_and_conflicting_attribution_never_price
    catalog = AgentRuntime::Execution::ModelCatalog.new(data)
    snapshot = catalog.resolve("route")
    usage = {"input" => 1, "cached_input" => 2, "output" => 0, "reasoning" => 0}
    assert_nil catalog.cost(snapshot, attribution: evidence(catalog, snapshot), usage: usage)["amount"]
    assert_equal "mismatch", catalog.attribute(snapshot, gateway_model: "base", gateway_provider: "wrong")["gateway_status"]
    attribution = catalog.attribute(snapshot, gateway_model: "wrong")
    assert_nil catalog.cost(snapshot, usage: usage.merge("input" => 3), attribution: attribution)["amount"]
  end

  def test_additive_categories_zero_and_malformed_configuration
    source = data
    source["routes"]["route"]["accounting"].merge!("input_includes_cached" => false, "output_includes_reasoning" => false)
    catalog = AgentRuntime::Execution::ModelCatalog.new(source)
    snapshot = catalog.resolve("route")
    assert_equal "45/1", catalog.cost(snapshot, attribution: evidence(catalog, snapshot), usage: {"input" => 10, "cached_input" => 4, "output" => 5, "reasoning" => 2})["amount"]
    assert_equal "0/1", catalog.cost(snapshot, attribution: evidence(catalog, snapshot), usage: %w[input cached_input output reasoning].to_h { |key| [key, 0] })["amount"]
    assert_raises(ArgumentError) { AgentRuntime::Execution::ModelCatalog.new(source.merge("routes" => nil)) }
    source["pricing"]["shared"]["rates"] = nil
    assert_nil catalog.cost(AgentRuntime::Execution::ModelCatalog.new(source).resolve("route"), usage: {})["amount"]
    assert_nil catalog.cost(snapshot, attribution: evidence(catalog, snapshot), usage: {"input" => -1})["amount"]
  end

  def test_unknown_attribution_and_conflicting_attestation_are_unpriced
    catalog = AgentRuntime::Execution::ModelCatalog.new(data)
    snapshot = catalog.resolve("route")
    usage = %w[input cached_input output reasoning].to_h { |key| [key, 0] }
    assert_nil catalog.cost(snapshot, usage: usage)["amount"]
    assert_nil catalog.cost(snapshot, usage: usage, attribution: {"requested" => snapshot, "gateway_status" => "match"})["amount"]
    unknown = catalog.attribute(snapshot, gateway_model: "base")
    assert_nil catalog.cost(snapshot, usage: usage, attribution: unknown)["amount"]
    conflict = catalog.attribute(snapshot, gateway_model: "base", gateway_provider: "fixture", gateway_endpoint: "http://localhost/v1", served: {"model" => "other", "provider" => "fixture"})
    assert_nil catalog.cost(snapshot, usage: usage, attribution: conflict)["amount"]
  end
end
