require_relative "authorized_comparison"
require_relative "../execution/local_token_provider"
require_relative "scientific_report"

module AgentRuntime
  module Benchmarks
    # Token-only local OmniRoute assembly; shares submission, independent regrade,
    # freeze and report machinery with the authorized HTTPS comparison.
    class LocalComparison
      ROOT = File.expand_path("../../..", __dir__)
      INTENT = File.join(ROOT, "experiments/omniroute-luna6-token-observation.json")
      LEDGER = File.join(ROOT, ".agru/authorizations/omniroute-luna6-20261116.tokens.jsonl")

      def self.manifest
        data = JSON.parse(JSON.generate(AuthorizedComparison.manifest.data))
        data["experiment_id"] = "research-omniroute-token-staged-v2"
        data.fetch("limits").merge!("cell_inference_requests" => 12, "planner_inference_requests" => 3,
          "coder_inference_requests" => 7, "reviewer_inference_requests" => 2)
        model = data.fetch("models").first
        model["model"] = Execution::TokenBudgetLedger::MODEL
        profile = model.fetch("model_profile")
        profile["model"] = Execution::TokenBudgetLedger::MODEL
        profile["provider"] = "omniroute"
        profile.fetch("tool_policy")["endpoint"] = "http://127.0.0.1:20128/v1/chat/completions"
        profile.fetch("tool_policy")["route"] = "local-gateway"
        profile["pricing"] = {"status" => "unknown", "source" => "token-only-no-pricing"}
        ExperimentManifest.new(data)
      end

      def self.bindings(assets:)
        inventory = Dir.glob(File.join(File.realpath(assets), "**", "*"), File::FNM_DOTMATCH)
          .select { |path| File.file?(path) }.sort.to_h do |path|
          raise ArgumentError, "symlink asset forbidden" if File.symlink?(path)
          [path.delete_prefix(File.realpath(assets) + "/"), Digest::SHA256.file(path).hexdigest]
        end
        {"schema" => "agru-local-token-comparison-v1", "manifest_digest" => manifest.digest,
         "release_identity" => ReleaseIdentity.capture(root: ROOT),
         "assets" => File.realpath(assets), "asset_inventory_digest" => Digest::SHA256.hexdigest(JSON.generate(inventory)), "ledger_path" => LEDGER,
         "intent_digest" => Digest::SHA256.file(INTENT).hexdigest,
         "model" => Execution::TokenBudgetLedger::MODEL, "total_tokens" => 1_000_000_000,
         "limits" => {"cell_inference_requests" => 12, "planner_inference_requests" => 3,
                      "coder_inference_requests" => 7, "reviewer_inference_requests" => 2, "completion_tokens" => 32000,
                      "input_allowance" => 2_048_576, "max_body_bytes" => 1_048_576},
         "financial_exposure" => "not_hard_bounded"}
      end

      def initialize(root:, assets:, provider_factory: nil, test_ledger_path: nil)
        @root, @assets = File.expand_path(root), File.expand_path(assets)
        @provider_factory = provider_factory
        raise ArgumentError, "test ledger requires injected provider" if test_ledger_path && !provider_factory
        @test_ledger_path = test_ledger_path
      end

      def run(authorization_path:, credential_file:, allow_live: false)
        raise ArgumentError, "explicit local live opt-in required" unless allow_live
        authorization = JSON.parse(File.read(authorization_path))
        raise ArgumentError, "local token authorization mismatch" unless authorization.fetch("bindings") == self.class.bindings(assets: @assets)
        raise ArgumentError, "local token authorization expired" unless authorization.fetch("expires_at") > Time.now.to_f
        stat = File.stat(credential_file)
        raise ArgumentError, "credential must be private regular nonsymlink" unless stat.file? && !File.symlink?(credential_file) && (stat.mode & 0o077).zero?
        credential = File.read(credential_file).strip
        raise ArgumentError, "invalid credential" if credential.empty? || credential.match?(/[\r\n]/)
        ledger_options = {"path" => @test_ledger_path || LEDGER, "intent_digest" => Digest::SHA256.file(INTENT).hexdigest, "total_tokens" => 1_000_000_000}
        ledger = Execution::TokenBudgetLedger.new(**ledger_options.transform_keys(&:to_sym))
        raise ArgumentError, "token_budget_halted: resolve saved identity evidence before starting an experiment" if ledger.snapshot.fetch("halted")
        manifest = self.class.manifest
        if @provider_factory
          data = JSON.parse(JSON.generate(manifest.data))
          data["subset_role"] = "local-transport-simulation-no-provider-calls"
          manifest = ExperimentManifest.new(data)
        end
        execution_id = "#{manifest.data.fetch("experiment_id")}-#{SecureRandom.hex(8)}"
        directory = File.join(@root, "local-token-comparison", execution_id)
        FileUtils.mkdir_p(directory, mode: 0o700)
        store = Store.new(File.join(@root, "store"))
        grader = NL2RepoAuditedGrader.new(store: store, root: @assets)
        adapter = Adapters::NL2Repo.new(store: store, root: @assets, audited_grader: grader)
        registry = Registry.new
        registry.register("nl2repo", adapter)
        factory = @provider_factory ? -> { @provider_factory.call(ledger_options, directory) } : -> {
          Execution::LocalTokenProvider.new(root: ROOT, ledger: ledger_options,
            credential: credential, audit_path: File.join(directory, "provider-audit.jsonl"))
        }
        solvers = AuthorizedComparison::ARMS.to_h do |arm|
          runtime_adapter = AttemptAdapter.new(provider_factory: factory, directory: directory,
            model_profile: manifest.data.fetch("models").first.fetch("model_profile"))
          solver = case arm
          when "single-agent" then Solvers::OpenCode.new(store: store, adapter: runtime_adapter, live: true)
          when "fixed-workflow" then Solvers::FixedWorkflow.new(store: store, adapter: runtime_adapter, live: true)
          else Solvers::ComparativeDSL.new(store: store, adapter: runtime_adapter, live: true)
          end
          [arm, solver]
        end
        runner = Runner.new(token_solvers: solvers, token_manifest: manifest, store: store,
          root: File.join(directory, "work"), registry: registry, simulated: !!@provider_factory)
        coordinator = ComparativeExperiment.new(store: store, runner: runner)
        verification = coordinator.run(manifest: manifest, evidence_kind: @provider_factory ? "local_transport_simulation" : "live_provider", execution_id: execution_id)
        path = File.join(directory, "verification.json")
        File.write(path, JSON.pretty_generate(verification) + "\n")
        bundle = coordinator.freeze(experiment_id: execution_id, destination: File.join(directory, "frozen"), verification: verification)
        ComparativeExperiment.verify_freeze(bundle.fetch("path"))
        report = store.report(execution_id)
        File.write(File.join(directory, "report.md"), ScientificReport.new(store: store).render(experiment_id: execution_id, evidence_kind: @provider_factory ? "local_transport_simulation" : "live_provider"))
        File.write(File.join(directory, "report.json"), JSON.pretty_generate(report) + "\n")
        {"execution_id" => execution_id, "verification" => path, "bundle" => bundle, "report" => report, "token_ledger" => ledger.snapshot}
      end

      class AttemptAdapter
        def initialize(provider_factory:, directory:, model_profile:)
          @factory, @directory, @profile = provider_factory, directory, model_profile
        end

        def execute(request)
          cell_id = JSON.parse(File.read(File.join(@directory, "active-cell.json"))).fetch("cell_id")
          active = JSON.parse(File.read(File.join(@directory, "active-cell.json")))
          remaining = active.fetch("deadline") - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return AgentRuntime::Result.new(status: "timeout", outputs: {}, error: "local cell deadline exhausted") unless remaining.positive?
          request = request.dup
          role = (request.config || {})["role"] || "solve"
          steps = {"planner" => 3, "coder" => 7, "reviewer" => 2, "solve" => 12}.fetch(role)
          request.config = request.config.merge("prompt" => request.config.fetch("prompt") +
            "\n\nYou have at most #{steps} inference turns including your final response. Batch independent tools in one turn. Reserve the final turn for an honest handoff; do not claim tests or changes not actually completed.")
          request.timeout = [request.timeout || remaining, remaining].min
          provider = @factory.call
          stage_options = provider.is_a?(Execution::LocalTokenProvider) ? {timeout: request.timeout} : {}
          relay = provider.start(attempt_id: "#{request.run_id}:#{request.step_id}:#{request.attempt}",
            cell_id: cell_id, model_profile: @profile, **stage_options)
          helper = File.expand_path("../execution/local_token_bridge.cjs", __dir__)
          policy = Execution::SandboxRunner::MockRelayPolicy.new(volume: relay.fetch("volume"), helper: helper,
            helper_sha256: Digest::SHA256.file(helper).hexdigest)
          sandbox = Execution::SandboxRunner.new(image: SimulatedComparison::IMAGE,
            limits: {"cpus" => 1, "memory_bytes" => 1073741824, "pids" => 128, "tmpfs_bytes" => 134217728}, network_policy: policy)
          launch = Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode",
            executable_sha256: SimulatedComparison::EXECUTABLE_DIGEST, endpoint: "http://127.0.0.1:18080/v1",
            model: "omniroute/cx/gpt-6-luna-low", provider: "omniroute", wire_model: "cx/gpt-6-luna-low",
            mock_only: false, transport_mode: "provider_relay", steps: steps)
          result = AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: sandbox, launch: launch).execute(request)
          File.open(File.join(@directory, "sandbox-diagnostics.jsonl"), "a", 0o600) { |file| file.puts(JSON.generate("cell_id" => cell_id, "status" => result.status, "error" => result.error, "logs" => result.logs)) }
          result
        ensure
          provider&.close
        end
      end

      class Runner < ExperimentRunner
        def initialize(token_solvers:, token_manifest:, simulated: false, **options)
          @token_manifest = token_manifest
          @simulated = simulated
          super(**options, solvers: token_solvers)
        end

        private

        def execute_cell(report, cell, adapter)
          File.write(File.join(File.dirname(@root), "active-cell.json"), JSON.generate("cell_id" => cell.fetch("id"), "deadline" => Process.clock_gettime(Process::CLOCK_MONOTONIC) + @token_manifest.data.fetch("limits").fetch("timeout")))
          super
        end

        def validate_live!(manifest, adapter, _authorization)
          normalized = manifest.data.merge("experiment_id" => @token_manifest.data.fetch("experiment_id"))
          raise ArgumentError, "local token manifest mismatch" unless ExperimentManifest.new(normalized).digest == @token_manifest.digest
          raise ArgumentError, "local token requires audited adapter" unless adapter.instance_of?(Adapters::NL2Repo) && adapter.audited_scoring?
        end

        def ordered_cells(manifest) = AuthorizedComparison.schedule(manifest)

        def execution_metadata(manifest, cells)
          {"execution_release_identity" => ReleaseIdentity.capture(root: ROOT),
           "offline_injected_provider" => @simulated, "live_provider" => !@simulated,
           "transport" => "local-token-gateway", "requested_model" => Execution::TokenBudgetLedger::MODEL,
           "pricing" => "not-used", "solver_configurations" => @solvers.transform_values(&:configuration),
           "planned_schedule" => cells.map { |cell| cell.fetch("id") }}
        end
      end
    end
  end
end
