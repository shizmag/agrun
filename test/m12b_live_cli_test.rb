require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/live_cli"
require_relative "../lib/agent_runtime/benchmarks/experiment_manifest"
require_relative "../lib/agent_runtime/benchmarks"
require "digest"

class M12bLiveCliTest < Minitest::Test
  def test_report_does_not_construct_solver_or_benchmark_adapter
    Dir.mktmpdir do |root|
      store = AgentRuntime::Store.new(root)
      store.save_report({"run_id" => "live-report", "kind" => "experiment", "manifest" => {"execution_mode" => "live", "repetitions" => 1}, "cells" => []})
      AgentRuntime::Benchmarks::ExperimentRunner.stub(:new, ->(**) { raise "runner constructed for report" }) do
        AgentRuntime::Benchmarks::Solvers::OpenCode.stub(:new, ->(**) { raise "solver constructed for report" }) do
          output, errors = capture_io do
            assert_equal 0, AgentRuntime::Benchmarks::CLI.new.run(["report", "live-report", "--root", root])
          end
          assert_empty errors
          assert_equal "live-report", JSON.parse(output).fetch("experiment_id")
        end
      end
    end
  end

  def manifest(executable)
    {"schema_version" => 1, "experiment_id" => "pilot", "benchmark" => {"name" => "nl2repo", "revision" => "pinned", "task_ids" => ["retrying"]},
     "solver_ids" => ["single-agent"], "models" => [{"id" => "pilot", "model_profile" => {"id" => "pilot", "provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "execution_kind" => "real_provider",
                                                                                          "tool_policy" => {"endpoint" => "http://localhost:20128/v1", "route" => "cx/gpt-6-luna-low", "executable" => executable, "executable_sha256" => Digest::SHA256.file(executable).hexdigest, "model_fallback" => false}}}],
     "repetitions" => 1, "limits" => {"timeout" => 10, "max_concurrent_sessions" => 1}, "execution_mode" => "live", "subset_role" => "smoke"}
  end

  def with_live_files
    Dir.mktmpdir do |root|
      executable = File.join(root, "inert")
      File.write(executable, "not executed")
      File.chmod(0o755, executable)
      data = manifest(executable)
      digest = AgentRuntime::Benchmarks::ExperimentManifest.new(data).digest
      scope = {"experiment_digest" => digest, "task" => "retrying", "solver" => "single-agent", "provider" => "omniroute", "endpoint" => "http://localhost:20128/v1", "route" => "cx/gpt-6-luna-low", "model" => "cx/gpt-6-luna-low", "mode" => "live"}
      manifest_path = File.join(root, "manifest.json")
      authorization_path = File.join(root, "authorization.json")
      File.write(manifest_path, JSON.generate(data))
      File.write(authorization_path, JSON.generate({"scope" => scope, "expires_at" => Time.now.to_f + 60, "financial_exposure" => "not_hard_bounded"}))
      yield root, manifest_path, authorization_path, data
    end
  end

  def test_run_rejects_missing_credential_before_adapter_launch
    with_live_files do |root, manifest_path, authorization_path, _data|
      previous = ENV.delete("OMNIROUTE_API_KEY")
      _, errors = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::LiveCLI.new.run(["run", manifest_path, "--authorization", authorization_path, "--root", root])
      end
      assert_match(/credential unavailable: OMNIROUTE_API_KEY/, errors)
      decision = JSON.parse(File.read(File.join(root, "live-preflight.json")))
      assert_equal false, decision.fetch("allowed")
    ensure
      ENV["OMNIROUTE_API_KEY"] = previous if previous
    end
  end

  def test_preflight_uses_independent_scope_and_never_persists_credential
    with_live_files do |root, manifest_path, authorization_path, _data|
      previous = ENV["OMNIROUTE_API_KEY"]
      ENV["OMNIROUTE_API_KEY"] = "fixture-secret-never-persist"
      fake = Object.new
      def fake.audited_scoring? = true
      def fake.load_task(id) = {"id" => id, "availability" => "verified"}

      def fake.prepare_solver_workspace(task:, workspace:)
        raise "workspace already exists" if File.exist?(workspace)
        FileUtils.mkdir_p(File.join(workspace, "repository"))
      end
      cli = AgentRuntime::Benchmarks::LiveCLI.new
      cli.define_singleton_method(:audited_adapter) { |_store| fake }
      cli.define_singleton_method(:verify_grader_image!) { true }
      output, errors = capture_io do
        assert_equal 0, cli.run(["preflight", manifest_path, "--authorization", authorization_path, "--root", File.join(root, ".agru")])
      end
      assert_empty errors
      assert_equal true, JSON.parse(output).fetch("allowed")
      receipt = File.read(File.join(root, ".agru/live-preflight.json"))
      refute_includes receipt, ENV.fetch("OMNIROUTE_API_KEY")
      data = JSON.parse(File.read(authorization_path))
      data.fetch("scope")["route"] = "different"
      File.write(authorization_path, JSON.generate(data))
      _, errors = capture_io do
        assert_equal 1, cli.run(["preflight", manifest_path, "--authorization", authorization_path, "--root", File.join(root, ".agru")])
      end
      assert_match(/authorization_scope_mismatch/, errors)
    ensure
      previous ? ENV["OMNIROUTE_API_KEY"] = previous : ENV.delete("OMNIROUTE_API_KEY")
    end
  end

  def test_run_returns_report_from_existing_experiment_runner
    with_live_files do |root, manifest_path, authorization_path, _data|
      previous = ENV["OMNIROUTE_API_KEY"]
      ENV["OMNIROUTE_API_KEY"] = "fixture-only"
      fake = Object.new
      def fake.audited_scoring? = true

      def fake.load_task(id) = {"id" => id, "availability" => "verified"}

      def fake.prepare_solver_workspace(task:, workspace:)
        FileUtils.mkdir_p(File.join(workspace, "repository"))
      end
      report = {"run_id" => "pilot", "status" => "completed"}
      runner = Object.new
      runner.define_singleton_method(:run) do |manifest:, live_authorization:|
        raise "missing authorization" unless live_authorization.instance_of?(AgentRuntime::Execution::LiveAuthorization)
        raise "wrong manifest" unless manifest.data.fetch("experiment_id") == "pilot"
        report
      end
      cli = AgentRuntime::Benchmarks::LiveCLI.new
      cli.define_singleton_method(:audited_adapter) { |_store| fake }
      cli.define_singleton_method(:verify_grader_image!) { true }
      AgentRuntime::Benchmarks::ExperimentRunner.stub(:new, runner) do
        output, errors = capture_io do
          assert_equal 0, cli.run(["run", manifest_path, "--authorization", authorization_path, "--root", File.join(root, ".agru")])
        end
        assert_empty errors
        assert_equal report, JSON.parse(output)
      end
    ensure
      previous ? ENV["OMNIROUTE_API_KEY"] = previous : ENV.delete("OMNIROUTE_API_KEY")
    end
  end

  def test_unsupported_financial_bound_is_rejected_before_launch
    with_live_files do |root, manifest_path, authorization_path, data|
      data.fetch("limits")["cost"] = 1
      File.write(manifest_path, JSON.generate(data))
      _, errors = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::LiveCLI.new.run(["run", manifest_path, "--authorization", authorization_path, "--root", root])
      end
      assert_match(/unsupported_hard_limit/, errors)
      assert_equal false, JSON.parse(File.read(File.join(root, "live-preflight.json"))).fetch("allowed")
    end
  end

  def test_missing_concrete_profile_id_is_rejected_during_preflight
    with_live_files do |root, manifest_path, authorization_path, data|
      data.fetch("models").first.fetch("model_profile").delete("id")
      File.write(manifest_path, JSON.generate(data))
      _, errors = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::LiveCLI.new.run(["preflight", manifest_path, "--authorization", authorization_path, "--root", root])
      end
      assert_match(/missing keyword: :id/, errors)
      assert_equal false, JSON.parse(File.read(File.join(root, "live-preflight.json"))).fetch("allowed")
    end
  end

  def test_missing_grader_image_is_denied_without_persisting_diagnostics
    with_live_files do |root, manifest_path, authorization_path, _data|
      previous = ENV["OMNIROUTE_API_KEY"]
      ENV["OMNIROUTE_API_KEY"] = "fixture-only"
      fake = Object.new
      def fake.audited_scoring? = true
      cli = AgentRuntime::Benchmarks::LiveCLI.new
      cli.define_singleton_method(:audited_adapter) { |_store| fake }
      process = Object.new
      process.define_singleton_method(:call) do |argv:, cwd:, timeout:|
        raise "unexpected command" unless argv == ["docker", "image", "inspect", AgentRuntime::Benchmarks::NL2RepoGrader::IMAGE] && timeout == 10
        {"status" => "failure", "exit_code" => 1, "stderr" => "private diagnostic"}
      end
      AgentRuntime::Adapters::ProcessRunner.stub(:new, -> { process }) do
        _, errors = capture_io do
          assert_equal 1, cli.run(["run", manifest_path, "--authorization", authorization_path, "--root", File.join(root, ".agru")])
        end
        assert_match(/audited grader image unavailable/, errors)
        receipt = File.read(File.join(root, ".agru/live-preflight.json"))
        refute_includes receipt, "private diagnostic"
        assert_equal false, JSON.parse(receipt).fetch("allowed")
      end
    ensure
      previous ? ENV["OMNIROUTE_API_KEY"] = previous : ENV.delete("OMNIROUTE_API_KEY")
    end
  end

  def test_missing_authorization_is_retained_without_starting_adapter
    Dir.mktmpdir do |root|
      output, errors = capture_io do
        assert_equal 1, AgentRuntime::Benchmarks::LiveCLI.new.run(["preflight", "missing.json", "--root", root])
      end
      assert_match(/authorization required/, errors)
      assert_empty output
      decision = JSON.parse(File.read(File.join(root, "live-preflight.json")))
      assert_equal false, decision.fetch("allowed")
      assert_equal "rejected", decision.fetch("status")
    end
  end

  def test_plan_does_not_require_authorization_or_credentials
    Dir.mktmpdir do |root|
      path = File.join(root, "manifest.json")
      File.write(path, JSON.generate({"experiment_id" => "draft"}))
      output, = capture_io do
        assert_equal 0, AgentRuntime::Benchmarks::LiveCLI.new.run(["plan", path, "--root", root])
      end
      data = JSON.parse(output)
      assert_equal false, data.fetch("provider_requests_performed")
      assert_equal "plan_only", data.fetch("status")
    end
  end
end
