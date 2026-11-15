require "json"
require "optparse"
require "fileutils"
require_relative "../execution/live_authorization"
require_relative "../execution/opencode_launch"
require_relative "experiment_manifest"
require_relative "experiment_runner"
require_relative "nl2repo_audited_grader"

module AgentRuntime
  module Benchmarks
    # Explicit local operator entrypoint; planning never starts OpenCode.
    class LiveCLI
      def run(argv)
        command = argv.shift
        options = {root: ".agru", authorization: nil}
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--authorization PATH") { |value| options[:authorization] = value }
        end.parse!(argv)
        root = File.expand_path(options.fetch(:root))
        if command == "plan"
          manifest = JSON.parse(File.read(argv.fetch(0)))
          puts JSON.pretty_generate({"status" => "plan_only", "provider_requests_performed" => false,
                                     "manifest" => manifest, "authorization_required" => true,
                                     "financial_ceiling" => nil, "usage_coverage" => "partial_cli_events"})
          return 0
        end
        raise ArgumentError, "unknown live command: #{command}" unless %w[preflight run].include?(command)
        raise ArgumentError, "live authorization required" unless options[:authorization]
        authorization_data = JSON.parse(File.read(options.fetch(:authorization)))
        authorization = Execution::LiveAuthorization.new(**authorization_data.slice("scope", "expires_at", "financial_exposure").transform_keys(&:to_sym))
        manifest = ExperimentManifest.new(JSON.parse(File.read(argv.fetch(0))))
        raise ArgumentError, "live manifest required" unless manifest.data.fetch("execution_mode") == "live"
        execute(command, manifest, authorization, root)
      rescue ArgumentError, KeyError, SystemCallError, AgentRuntime::Error, JSON::ParserError, OptionParser::ParseError => error
        if root
          persist_preflight(root, {"allowed" => false, "status" => "rejected", "reason" => error.message})
        end
        warn error.message
        1
      end

      private

      def execute(command, manifest, authorization, root)
        unsupported = manifest.data.fetch("limits").keys - %w[timeout max_concurrent_sessions max_attempts max_parallelism]
        raise ArgumentError, "unsupported_hard_limit" unless unsupported.empty?
        Execution::Budget::AdmissionConfig.new(wall_seconds: manifest.data.fetch("limits").fetch("timeout"),
          max_concurrent_sessions: manifest.data.fetch("limits").fetch("max_concurrent_sessions"),
          max_attempts: manifest.data.fetch("limits")["max_attempts"])
        profile = manifest.data.fetch("models").fetch(0).fetch("model_profile")
        Execution::Budget::ModelProfile.new(**profile.slice("id", "provider", "model", "execution_kind", "tool_policy").transform_keys(&:to_sym))
        policy = profile.fetch("tool_policy")
        unless profile.values_at("provider", "model", "execution_kind") == ["omniroute", "cx/gpt-6-luna-low", "real_provider"] &&
            policy.values_at("endpoint", "route", "model_fallback") == [Execution::OpenCodeLaunch::ENDPOINT, "cx/gpt-6-luna-low", false]
          raise ArgumentError, "live model, endpoint, route, or fallback mismatch"
        end
        scope = {"experiment_digest" => manifest.digest,
                 "task" => manifest.data.fetch("benchmark").fetch("task_ids").fetch(0),
                 "solver" => manifest.data.fetch("solver_ids").fetch(0),
                 "provider" => profile.fetch("provider"), "endpoint" => policy.fetch("endpoint"),
                 "route" => policy.fetch("route"), "model" => profile.fetch("model"), "mode" => "live"}
        authorization.preflight!(scope: scope)
        credential = ENV["OMNIROUTE_API_KEY"]
        raise ArgumentError, "credential unavailable: OMNIROUTE_API_KEY" unless credential.is_a?(String) && !credential.empty?
        launch = Execution::OpenCodeLaunch.new(executable: policy.fetch("executable"),
          executable_sha256: policy.fetch("executable_sha256"), credential: credential)
        raise ArgumentError, "resolved launch scope mismatch" unless launch.scope.all? { |key, value| scope.fetch(key) == value }
        store = Store.new(root)
        adapter = audited_adapter(store)
        raise ArgumentError, "audited grader unavailable" unless adapter.audited_scoring?
        verify_grader_image!
        task = adapter.load_task(scope.fetch("task"))
        raise ArgumentError, "task unavailable" unless task.fetch("availability") == "verified"
        FileUtils.mkdir_p(root)
        Dir.mktmpdir("live-preflight-", root) do |workspace|
          adapter.prepare_solver_workspace(task: task, workspace: File.join(workspace, "solver"))
        end
        decision = {"status" => "allowed", "allowed" => true, "scope" => scope,
                    "provider_requests_performed" => false, "credential_available" => true,
                    "financial_exposure" => "not_hard_bounded", "launch" => launch.to_h}
        persist_preflight(root, decision)
        if command == "preflight"
          puts JSON.pretty_generate(decision)
          return 0
        end
        execute_run(manifest, authorization, scope, launch, adapter, store, root)
      end

      def audited_adapter(store)
        dataset_root = File.join(Adapters::NL2Repo::ROOT, ".agru", "nl2repo")
        grader = NL2RepoAuditedGrader.new(store: store, root: dataset_root)
        Adapters::NL2Repo.new(root: dataset_root, store: store, audited_grader: grader)
      end

      def verify_grader_image!
        result = AgentRuntime::Adapters::ProcessRunner.new.call(
          argv: ["docker", "image", "inspect", NL2RepoGrader::IMAGE], cwd: Dir.pwd, timeout: 10
        )
        unless result.fetch("status") == "success" && result.fetch("exit_code") == 0
          raise ArgumentError, "audited grader image unavailable"
        end
        true
      end

      def execute_run(manifest, authorization, scope, launch, adapter, store, root)
        limits = manifest.data.fetch("limits")
        config = Execution::Budget::AdmissionConfig.new(wall_seconds: limits.fetch("timeout"),
          max_concurrent_sessions: limits.fetch("max_concurrent_sessions"), max_attempts: limits["max_attempts"])
        coordinator = Execution::Budget::Coordinator.new
        experiment = coordinator.open_scope(kind: "experiment", id: manifest.data.fetch("experiment_id"), config: config)
        scope_mutex = Mutex.new
        run_scopes = {}
        scopes = lambda do |request, _coordinator, _policy|
          scope_mutex.synchronize do
            chain = run_scopes[request.run_id] ||= [experiment, coordinator.open_scope(kind: "run",
              id: request.run_id, config: config, parent: experiment)]
            attempt_config = Execution::Budget::AdmissionConfig.new(wall_seconds: [request.timeout, config.to_h.fetch("wall_seconds")].min,
              max_attempts: 1, max_concurrent_sessions: 1)
            chain + [coordinator.open_scope(kind: "attempt", id: "#{request.step_id}:#{request.attempt}", config: attempt_config, parent: chain.last)]
          end
        end
        executor = AgentRuntime::Adapters::OpenCodeCLI.new(executable: launch.executable,
          live: true, budget: coordinator, scopes: scopes, authorization: authorization,
          authorization_scope: scope, launch_config: launch)
        solver = Solvers::OpenCode.new(adapter: executor, live: true)
        runner = ExperimentRunner.new(store: store, root: File.join(root, "live"),
          registry: {"nl2repo" => adapter}, solvers: {"single-agent" => solver})
        report = runner.run(manifest: manifest, live_authorization: authorization)
        puts JSON.pretty_generate(report)
        0
      end

      def persist_preflight(root, decision)
        FileUtils.mkdir_p(root)
        path = File.join(root, "live-preflight.json")
        raise ArgumentError, "preflight receipt is a symlink" if File.symlink?(path)
        File.write(path, JSON.pretty_generate(decision))
      end
    end
  end
end
