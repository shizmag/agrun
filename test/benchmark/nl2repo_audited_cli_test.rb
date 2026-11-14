require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks"
require "minitest/mock"
require_relative "../../lib/agent_runtime/benchmarks/cli"
require_relative "../../lib/agent_runtime/benchmarks/adapters/nl2repo"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_audited_grader"

class NL2RepoAuditedCLITest < Minitest::Test
  def test_datasets_explicitly_injects_audited_transport_at_dataset_root
    in_tmp do |directory|
      root = File.join(directory, ".agru")
      captured = []
      transport = Object.new
      factory = ->(**keywords) {
        captured << keywords
        transport
      }
      adapter_options = []
      adapter = Object.new
      adapter.define_singleton_method(:identity) { {"name" => "nl2repo"} }
      adapter.define_singleton_method(:availability) { {"grader_ready" => false, "runnable" => false} }
      AgentRuntime::Benchmarks::NL2RepoAuditedGrader.stub(:new, factory) do
        AgentRuntime::Benchmarks::Adapters::NL2Repo.stub(:new, ->(**keywords) {
          adapter_options << keywords
          adapter
        }) do
          out, err = capture_io do
            assert_equal 0, AgentRuntime::Benchmarks::CLI.new.run(["datasets", "nl2repo", "--root", root, "--offline", "--audited-scoring"])
          end
          assert_empty err
          result = JSON.parse(out)
          assert_equal true, result.fetch("audited_scoring").fetch("enabled")
          assert_equal false, result.fetch("readiness").fetch("grader_ready")
        end
      end
      assert_equal 1, captured.size
      assert_equal File.join(root, "nl2repo"), captured.first.fetch(:root)
      assert_instance_of AgentRuntime::Store, captured.first.fetch(:store)
      assert_same transport, adapter_options.first.fetch(:audited_grader)
      assert_same captured.first.fetch(:store), adapter_options.first.fetch(:store)
    end
  end

  def test_verify_flag_is_additive_and_does_not_claim_official_validation
    in_tmp do |directory|
      out, err = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::CLI.new.run(["verify", "nl2repo", "--root", File.join(directory, ".agru"), "--offline", "--audited-scoring"])
      end
      assert_empty err
      result = JSON.parse(out)
      assert_equal "blocked", result.fetch("status")
      assert_nil result.fetch("score")
      assert_equal "nl2repo-audited-v2", result.fetch("audited_scoring").fetch("protocol")
    end
  end

  def test_persisted_audited_regrade_requires_explicit_flag_before_attempt
    in_tmp do |directory|
      root = File.join(directory, ".agru")
      store = AgentRuntime::Store.new(root)
      store.save_report({"run_id" => "audited-cli", "experiment_id" => "audited-cli", "cells" => [{"id" => "cell", "grading_attempts" => [{"request" => {"benchmark" => "nl2repo", "audited_binding" => {"marker" => true}}}]}]})
      out, err = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::CLI.new.run(["regrade", "audited-cli", "cell", "--root", root, "--offline"])
      end
      assert_empty out
      assert_includes err, "audited regrade requires --audited-scoring"
      assert_equal 1, store.report("audited-cli").fetch("cells").first.fetch("grading_attempts").size
    end
  end

  def test_historical_regrade_rejects_silent_switch_to_audited
    in_tmp do |directory|
      root = File.join(directory, ".agru")
      store = AgentRuntime::Store.new(root)
      store.save_report({"run_id" => "legacy-cli", "experiment_id" => "legacy-cli", "cells" => [{"id" => "cell", "grading_attempts" => [{"request" => {"benchmark" => "nl2repo"}}]}]})
      out, err = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::CLI.new.run(["regrade", "legacy-cli", "cell", "--root", root, "--offline", "--audited-scoring"])
      end
      assert_empty out
      assert_includes err, "cannot change historical grading protocol"
      assert_equal 1, store.report("legacy-cli").fetch("cells").first.fetch("grading_attempts").size
    end
  end

  def test_plan_reports_explicit_selector_without_changing_manifest
    in_tmp do |directory|
      manifest = {"schema_version" => 1, "experiment_id" => "audited-plan", "benchmark" => {"name" => "fixture", "revision" => "fixture-v1", "task_ids" => ["half"]},
                  "solver_ids" => ["direct"], "models" => [{"id" => "fixture"}], "repetitions" => 1, "limits" => {"timeout" => 10}, "execution_mode" => "offline", "subset_role" => "development"}
      path = File.join(directory, "manifest.json")
      File.write(path, JSON.generate(manifest))
      out, err = capture_io do
        assert_equal 0, AgentRuntime::Benchmarks::CLI.new.run(["plan", path, "--root", File.join(directory, ".agru"), "--offline", "--audited-scoring"])
      end
      assert_empty err
      result = JSON.parse(out)
      assert_equal manifest, result.fetch("manifest")
      assert_equal true, result.fetch("audited_scoring").fetch("enabled")
      assert_equal 1, result.fetch("cells").size
    end
  end

  def test_without_flag_never_constructs_audited_grader
    in_tmp do |directory|
      AgentRuntime::Benchmarks::NL2RepoAuditedGrader.stub(:new, ->(**) { flunk "audited transport requires opt-in" }) do
        out, err = capture_io do
          assert_equal 0, AgentRuntime::Benchmarks::CLI.new.run(["datasets", "nl2repo", "--root", File.join(directory, ".agru"), "--offline"])
        end
        assert_empty err
        assert_equal false, JSON.parse(out).fetch("audited_scoring").fetch("enabled")
      end
    end
  end
end
