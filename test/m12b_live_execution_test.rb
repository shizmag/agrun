require_relative "test_helper"
require_relative "../lib/agent_runtime/adapters/opencode_cli"
require "digest"

class M12bLiveExecutionTest < Minitest::Test
  class RecordingRunner
    attr_reader :calls

    def initialize(status: "success", truncated: false, native_identity: {}, &after_call)
      @calls = []
      @status, @truncated = status, truncated
      @after_call = after_call
      @native_identity = native_identity
    end

    def call(**arguments)
      @calls << arguments
      @after_call&.call
      {"status" => @status, "stdout" => JSON.generate({"type" => "step_finish", "sessionID" => "ses_offline", **@native_identity,
        "part" => {"id" => "part_one", "messageID" => "msg_one", "sessionID" => "ses_offline",
                   "type" => "step-finish", "reason" => "stop", "tokens" => {"input" => 2, "output" => 1,
                                                                             "reasoning" => 0, "cache" => {"read" => 0, "write" => 0}}}}) + "\n",
       "stderr" => "", "exit_code" => 0, "duration" => 0.01,
       "stdout_truncated" => @truncated, "stderr_truncated" => false}
    end
  end

  def test_live_opt_in_alone_never_launches
    with_request do |request, executable|
      runner = RecordingRunner.new
      result = AgentRuntime::Adapters::OpenCodeCLI.new(runner: runner, executable: executable, live: true).execute(request)
      assert_equal "blocked", result.status
      assert_empty runner.calls
    end
  end

  def test_authorized_exact_live_profile_can_reach_only_recording_runner
    assert_live_recording_launch
  end

  def test_observed_native_identity_mismatch_fails_without_erasing_evidence
    assert_live_recording_launch(native_identity: {"providerID" => "fallback", "modelID" => "other"})
  end

  def assert_live_recording_launch(native_identity: {})
    with_request do |request, executable|
      request.config["model_profile"].merge!("provider" => "omniroute", "model" => "cx/gpt-6-luna-low", "execution_kind" => "real_provider")
      runner = RecordingRunner.new(native_identity: native_identity)
      launch = AgentRuntime::Execution::OpenCodeLaunch.new(executable: executable,
        executable_sha256: Digest::SHA256.file(executable).hexdigest, credential: "offline-test-not-a-provider-secret")
      scope = launch.scope.merge("experiment_digest" => "a" * 64, "task" => "task", "solver" => "solver", "mode" => "live")
      authorization = AgentRuntime::Execution::LiveAuthorization.new(scope: scope,
        expires_at: Time.now.to_f + 60, financial_exposure: "not_hard_bounded")
      request.config["model_profile"]["tool_policy"] = {"endpoint" => scope.fetch("endpoint"),
        "route" => scope.fetch("route"), "model_fallback" => false}
      coordinator = AgentRuntime::Execution::Budget::Coordinator.new
      policy = AgentRuntime::Execution::Budget::AdmissionConfig.new(wall_seconds: 3, max_concurrent_sessions: 1)
      experiment = coordinator.open_scope(kind: "experiment", id: "experiment", config: policy)
      run = coordinator.open_scope(kind: "run", id: request.run_id, config: policy, parent: experiment)
      attempt_policy = AgentRuntime::Execution::Budget::AdmissionConfig.new(wall_seconds: 3,
        max_attempts: 1, max_concurrent_sessions: 1)
      attempt = coordinator.open_scope(kind: "attempt", id: "#{request.step_id}:#{request.attempt}", config: attempt_policy, parent: run)
      scopes = [experiment, run, attempt]
      result = adapter(executable, runner, authorization: authorization, authorization_scope: scope,
        launch_config: launch, budget: coordinator, scopes: scopes).execute(request)
      if native_identity.empty?
        assert_equal "success", result.status, result.error.inspect
      else
        assert_equal "failure", result.status, result.error.inspect
        assert_equal "model_identity_mismatch", result.error.fetch("code")
        assert_includes result.logs.fetch("execution").fetch("model_identity_discrepancies"), native_identity
        refute result.retry_safe
      end
      assert_equal 1, runner.calls.length
      assert_includes runner.calls.first.fetch(:argv), "omniroute/cx/gpt-6-luna-low"
    end
  end

  def test_callback_receipt_cannot_authorize_live_execution
    with_request do |request, executable|
      request.config["model_profile"]["execution_kind"] = "real_provider"
      runner = RecordingRunner.new
      authorization = ->(**_) { {"mode" => "live"} }
      result = adapter(executable, runner, authorization: authorization).execute(request)
      assert_equal "blocked", result.status
      assert_empty runner.calls
    end
  end

  def test_observed_launch_does_not_inherit_opencode_overrides_or_ruby_preload
    with_request do |request, executable|
      with_environment("OPENCODE_CONFIG_CONTENT" => '{"mcp":{"unexpected":{}}}', "RUBYOPT" => "-runexpected") do
        runner = RecordingRunner.new
        result = adapter(executable, runner).execute(request)
        assert_equal "success", result.status
        environment = runner.calls.fetch(0).fetch(:env)
        %w[OPENCODE_CONFIG_CONTENT RUBYOPT].each do |key|
          assert environment.key?(key), "ambient #{key} must be explicitly replaced or removed"
          refute_equal ENV.fetch(key), environment[key]
        end
      end
    end
  end

  def test_observed_launch_uses_private_home_and_xdg_roots_outside_repository
    with_request do |request, executable|
      runner = RecordingRunner.new
      adapter(executable, runner).execute(request)
      environment = runner.calls.fetch(0).fetch(:env)
      %w[HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME].each do |key|
        path = environment[key]
        assert path.is_a?(String) && path.start_with?("/"), "#{key} needs an explicit private absolute root"
        refute_equal ENV[key], path
        refute path.start_with?(request.workspace + "/"), "CLI state must not enter the submitted repository"
      end
    end
  end

  def test_timeout_and_cancellation_override_successful_terminal_event
    %w[timeout cancelled].each do |status|
      with_request do |request, executable|
        runner = RecordingRunner.new(status: status)
        result = adapter(executable, runner).execute(request)
        assert_equal status, result.status
        refute_equal "success", result.status
        assert_equal "ses_offline", result.session_id
      end
    end
  end

  def test_truncated_protocol_never_establishes_success
    with_request do |request, executable|
      result = adapter(executable, RecordingRunner.new(truncated: true)).execute(request)
      refute_equal "success", result.status
      assert result.error
    end
  end

  def test_repository_collection_failure_preserves_execution_evidence
    with_request do |request, executable|
      request.inputs["repository"] = request.workspace
      runner = RecordingRunner.new { FileUtils.remove_entry(request.workspace) }
      result = adapter(executable, runner).execute(request)
      assert_equal "failure", result.status
      assert_empty result.outputs
      assert result.logs.fetch("execution").fetch("admission").fetch("allowed")
      assert_equal "ses_offline", result.session_id
    end
  end

  private

  def adapter(executable, runner, **options)
    AgentRuntime::Adapters::OpenCodeCLI.new(runner: runner, executable: executable, live: true,
      fixture_sha256: Digest::SHA256.file(executable).hexdigest, **options)
  end

  def with_request
    in_tmp do |root|
      executable = File.join(root, "never-executed-cli")
      File.write(executable, "#!/bin/sh\nexit 99\n")
      File.chmod(0o700, executable)
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      request = AgentRuntime::Request.new(run_id: "run", step_id: "solve", attempt: 1,
        inputs: {}, config: {"prompt" => "authorized specification only", "outputs" => {"answer" => "json"},
                             "model_profile" => {"id" => "offline", "provider" => "fixture", "model" => "deterministic",
                                                 "execution_kind" => "offline_fixture", "tool_policy" => {}},
                             "budget_policy" => {"wall_seconds" => 3, "max_attempts" => 1, "max_concurrent_sessions" => 1}},
        workspace: workspace, timeout: 2, cancellation: AgentRuntime::Cancellation.new)
      yield request, executable
    end
  end

  def with_environment(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
