require "json"
require_relative "process_runner"
require_relative "git_patch"
require_relative "../execution/event_stream"
require_relative "../execution/usage"
require_relative "../execution/budget"
require_relative "../execution/redaction"
require "digest"
require "securerandom"

module AgentRuntime
  module Adapters
    class OpenCodeCLI
      def initialize(runner: ProcessRunner.new, executable: "opencode", live: false,
        fixture_sha256: nil, budget: nil, scopes: nil, authorization: nil)
        @runner, @executable, @live = runner, executable, live
        @fixture_sha256, @budget, @scopes, @authorization = fixture_sha256, budget, scopes, authorization
        @scope_mutex = Mutex.new
        @local_scopes = {}
      end

      def timeout_cleanup_grace = 1.0

      def execute(request)
        config = request.config || {}
        unless fixture_valid?
          decision = {"admitted" => false, "reason" => "offline_fixture_identity_required"}
          yield decision if block_given?
          return Result.new(status: "blocked", outputs: {}, error: {"type" => "authorization", "message" => decision["reason"]},
            logs: {"execution" => {"schema_version" => "m12a-execution-v1", "outcome" => "blocked", "admission" => decision}})
        end
        return execute_observed(request) { |decision| yield decision if block_given? } if config["model_profile"]
        unless @live || config["live"] == true
          return Result.new(status: "blocked", outputs: {}, error: {"type" => "live_opt_in_required", "message" => "OpenCode requires explicit live: true"}, logs: {})
        end
        # Legacy fixtures remain compatible, but never receive ambient provider
        # credentials or permission to launch an unregistered executable.
        prompt = config.fetch("prompt") { request.inputs.fetch("prompt") }
        raise ArgumentError, "prompt must be a nonempty string" unless prompt.is_a?(String) && !prompt.empty?
        argv = [@executable, "run", "--format", "json", "--standalone"]
        {"model" => "--model", "agent" => "--agent", "session_id" => "--session"}.each do |key, flag|
          argv.concat([flag, config[key]]) if config[key]
        end
        argv.concat(["--", prompt])
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        execution, patch = GitPatch.new(directory).capture do
          @runner.call(argv: argv, cwd: directory, timeout: request.timeout,
            cancellation: request.cancellation, env: fixture_environment(config))
        end
        result = translate(execution, request, config)
        result.outputs["patch"] = patch
        result
      rescue ArgumentError, KeyError => error
        Result.new(status: "failure", outputs: {}, error: {"type" => "configuration", "message" => error.message}, logs: {})
      end

      private

      def fixture_valid?
        @executable.is_a?(String) && @executable.start_with?("/") &&
          File.expand_path(@executable) == @executable && !File.symlink?(@executable) &&
          @fixture_sha256.is_a?(String) && @fixture_sha256.match?(/\A[0-9a-f]{64}\z/) &&
          File.file?(@executable) && File.executable?(@executable) &&
          Digest::SHA256.file(@executable).hexdigest == @fixture_sha256
      rescue SystemCallError
        false
      end

      public def offline_fixture?
        fixture_valid?
      end

      def execute_observed(request)
        config = request.config
        secrets = config.fetch("env", {}).filter_map { |key, value| value if Execution::Redaction::SENSITIVE_KEY.match?(key) }
        frozen_config = Execution::Redaction.redact(JSON.parse(JSON.generate(config)), secrets: secrets)
        profile_data = frozen_config.fetch("model_profile")
        fields = profile_data.slice("id", "provider", "model", "execution_kind", "tool_policy")
        profile = Execution::Budget::ModelProfile.new(**fields.transform_keys(&:to_sym))
        policy = Execution::Budget::AdmissionConfig.new(**config.fetch("budget_policy").transform_keys(&:to_sym))
        coordinator = @budget || @scope_mutex.synchronize { @local_budget ||= Execution::Budget::Coordinator.new }
        scopes = admission_scopes(coordinator, policy, request)
        experiment = scopes.find { |scope| scope.kind == "experiment" }
        authorization = @authorization || lambda do |**_input|
          {"mode" => "offline_fixture", "executable" => @executable, "sha256" => @fixture_sha256,
           "profile_digest" => Digest::SHA256.hexdigest(IR.dump(profile.to_h)),
           "experiment_id" => experiment.id, "run_id" => request.run_id}
        end
        lease = coordinator.admit(scopes: scopes, profile: profile, request: request,
          executable: @executable, executable_sha256: @fixture_sha256, authorization: authorization) do |decision|
          yield decision.to_h if block_given?
        end
        admitted = lease.is_a?(Execution::Budget::Lease)
        decision = admitted ? lease.decision.to_h : lease.to_h
        unless admitted
          return Result.new(status: "blocked", outputs: {}, error: {"type" => "admission", "message" => decision["reason"]},
            logs: {"execution" => {"schema_version" => "m12a-execution-v1", "admission" => decision, "outcome" => "blocked"}})
        end
        prompt = config.fetch("prompt") { request.inputs.fetch("prompt") }
        raise ArgumentError, "prompt must be a nonempty string" unless prompt.is_a?(String) && !prompt.empty?
        argv = [@executable, "run", "--format", "json", "--standalone", "--model", "#{profile_data.fetch("provider")}/#{profile_data.fetch("model")}"]
        argv.concat(["--agent", config["agent"]]) if config["agent"]
        argv.concat(["--", prompt])
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        identity = {"run_id" => request.run_id, "step_id" => request.step_id, "attempt" => request.attempt,
                    "invocation_id" => SecureRandom.uuid, "workspace" => directory}
        remaining = coordinator.remaining_timeout(lease: lease)
        raise ArgumentError, "budget expired before launch" unless remaining
        execution = patch = artifact_error = nil
        begin
          execution, patch = GitPatch.new(directory).capture do
            execution = @runner.call(argv: argv, cwd: directory, timeout: remaining,
              cancellation: request.cancellation, env: fixture_environment(config))
          end
        rescue => error
          raise unless execution
          artifact_error = {"type" => "artifact_collection", "message" => "Artifact collection failed after execution", "error_class" => error.class.name}
        end
        execution = Execution::Redaction.redact(execution, secrets: secrets)
        trace = Execution::EventStream.parse(stdout: execution.fetch("stdout", ""), stderr: execution.fetch("stderr", ""),
          stdout_truncated: execution["stdout_truncated"] || false, stderr_truncated: execution["stderr_truncated"] || false,
          exit_code: execution["exit_code"], process_status: execution["status"], profile: profile_data, identity: identity)
        normalized = Execution::Usage.normalize(requests: trace.fetch("requests"), complete: false, pricing: profile_data["pricing"])
        trace.merge!("usage" => normalized.fetch("usage"), "admission" => decision, "process" => execution,
          "launch_observed" => true,
          "model_profile" => profile_data, "frozen_config" => frozen_config,
          "runtime" => {"ruby" => RUBY_DESCRIPTION, "adapter_protocol" => "opencode-2.3.0"},
          "redaction_applied" => true,
          "attempt_id" => "#{request.run_id}/#{request.step_id}/#{request.attempt}")
        if trace.fetch("usage").fetch("coverage").fetch("conflicting_requests").positive?
          trace["outcome"] = "unknown" unless %w[timeout cancelled failure].include?(trace["outcome"])
          trace["completion"]["operationally_complete"] = false
          trace["protocol_error"] ||= {"type" => "protocol", "code" => "conflicting_usage", "message" => "Root-step usage observations conflict"}
        end
        outputs = {"patch" => patch, "repository" => directory, "text" => trace.fetch("events").select { |event| event["type"] == "text" }.map { |event| event.dig("part", "text").to_s }.join}
        if artifact_error
          trace["cleanup"] = {"errors" => [artifact_error]}
          trace["outcome"] = "failure" unless %w[timeout cancelled].include?(trace["outcome"])
          trace["completion"]["operationally_complete"] = false
          outputs = {}
        end
        Result.new(status: trace.fetch("outcome"), outputs: outputs,
          error: artifact_error || trace["protocol_error"] || execution["error"], duration: execution["duration"],
          usage: normalized["usage"], cost: nil, logs: {"execution" => trace}, session_id: trace["session_id"], retry_safe: false)
      rescue ArgumentError, KeyError => error
        Result.new(status: "blocked", outputs: {}, error: {"type" => "configuration", "message" => error.message},
          logs: {"execution" => {"schema_version" => "m12a-execution-v1", "outcome" => "blocked", "admission" => {"admitted" => false, "reason" => "invalid_configuration"}}})
      rescue SystemCallError => error
        Result.new(status: "failure", outputs: {}, retry_safe: true,
          error: {"type" => "launch", "classification" => "transport", "message" => error.class.name},
          logs: {"execution" => {"schema_version" => "m12a-execution-v1", "outcome" => "failure",
                                 "launch_observed" => false, "admission" => decision, "identity" => identity, "model_profile" => profile_data}})
      ensure
        coordinator.release(lease: lease) if admitted
      end

      def admission_scopes(coordinator, policy, request)
        return @scopes.call(request, coordinator, policy) if @scopes.respond_to?(:call)
        return @scopes if @scopes
        @scope_mutex.synchronize do
          key = [coordinator.object_id, request.run_id]
          experiment, run = @local_scopes[key] ||= begin
            experiment = coordinator.open_scope(kind: "experiment", id: request.run_id, config: policy)
            [experiment, coordinator.open_scope(kind: "run", id: request.run_id, config: policy, parent: experiment)]
          end
          attempt_policy = Execution::Budget::AdmissionConfig.new(wall_seconds: [request.timeout, policy.to_h.fetch("wall_seconds")].min,
            max_attempts: 1, max_concurrent_sessions: 1)
          [experiment, run, coordinator.open_scope(kind: "attempt", id: "#{request.step_id}:#{request.attempt}", config: attempt_policy, parent: run)]
        end
      end

      def fixture_environment(config)
        inherited = ENV.keys.select { |key| Execution::Redaction::SENSITIVE_KEY.match?(key) }.to_h { |key| [key, nil] }
        configured = config.fetch("env", {}).reject { |key, _| Execution::Redaction::SENSITIVE_KEY.match?(key) }
        inherited.merge(configured)
      end

      def translate(execution, request, config)
        raise JSON::ParserError, "captured output was truncated" if execution["truncated"] || execution["stdout_truncated"] || execution["stderr_truncated"]
        events = execution["stdout"].lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
        raise JSON::ParserError, "events must be JSON objects" unless events.all? { |event| event.is_a?(Hash) }
        text = events.select { |event| event["type"] == "text" }.map { |event| event.dig("part", "text").to_s }.join
        finishes = events.select { |event| event["type"] == "step_finish" }
        error_event = events.find { |event| event["type"] == "error" }
        status = execution["status"]
        status = "failure" if status == "success" && error_event
        status = "blocked" if !%w[timeout cancelled].include?(status) && error_event && JSON.generate(error_event).match?(/permission|approval|denied/i)
        status = "unknown" if status == "success" && finishes.empty?
        session_id = events.rfind { |event| event["sessionID"] }&.fetch("sessionID")
        usage = finishes.filter_map { |event| event.dig("part", "tokens") }
        costs = finishes.filter_map { |event| event.dig("part", "cost") }
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        observed_model = events.filter_map { |event| event.dig("part", "modelID") || event["modelID"] }.last
        Result.new(status: status, outputs: {"text" => text, "repository" => directory, "requested_model" => config["model"]},
          error: (status == "success") ? nil : (error_event || {"type" => status, "message" => "OpenCode #{status}"}),
          duration: execution["duration"], logs: execution.slice("stdout", "stderr", "cleanup"),
          session_id: session_id, model: observed_model, usage: usage.empty? ? nil : {"steps" => usage},
          cost: costs.empty? ? nil : costs.sum)
      rescue JSON::ParserError, TypeError, NoMethodError => error
        Result.new(status: (execution["status"] == "success") ? "unknown" : execution["status"],
          outputs: {}, error: {"type" => "invalid_output", "message" => "invalid OpenCode JSON events: #{error.message}"},
          duration: execution["duration"], logs: execution.slice("stdout", "stderr", "cleanup"))
      end
    end
  end
end
