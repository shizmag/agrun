require_relative "simulated_comparison"
require_relative "../execution/authorized_provider"
require_relative "../execution/authorized_provider_launcher"
require_relative "../execution/provider_budget_ledger"

module AgentRuntime
  module Benchmarks
    # Explicit opt-in assembly. Consent files are trusted operator input, not signatures.
    class AuthorizedComparison
      ARMS = %w[single-agent fixed-workflow dsl].freeze
      MANIFEST = File.expand_path("../../../experiments/research-authorized-operational.json", __dir__)

      def self.manifest(protocol: "operational")
        raise ArgumentError, "unknown authorized protocol" unless %w[operational compute].include?(protocol)
        path = (protocol == "compute") ? MANIFEST.sub("operational.json", "compute.json") : MANIFEST
        ExperimentManifest.new(JSON.parse(File.read(path)))
      end

      def self.schedule(manifest = self.manifest)
        (1..3).flat_map do |repetition|
          ARMS.rotate(repetition - 1).map do |arm|
            manifest.cells.find { |cell| cell["solver_id"] == arm && cell["repetition"] == repetition }
          end
        end
      end

      def self.canonical_ledger_path(path)
        absolute = File.expand_path(path)
        raise ArgumentError, "ledger path must be absolute and nonsymlink" unless path == absolute && !File.symlink?(absolute)
        parent = File.dirname(absolute)
        raise ArgumentError, "ledger parent must exist and be canonical" unless File.directory?(parent) && File.realpath(parent) == parent
        absolute
      end

      def self.bindings(origin:, assets:, ledger_path:, protocol: "operational")
        manifest = self.manifest(protocol: protocol)
        ledger_path = canonical_ledger_path(ledger_path)
        raise ArgumentError, "asset root must exist" unless File.directory?(assets) && !File.symlink?(assets)
        asset_inventory = Dir.glob(File.join(File.expand_path(assets), "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
          raise ArgumentError, "symlink asset forbidden" if File.symlink?(path)
          [path.delete_prefix("#{File.expand_path(assets)}/"), Digest::SHA256.file(path).hexdigest]
        end
        grader = NL2RepoAuditedGrader.new(store: nil, root: assets).identity
        {"experiment_digest" => manifest.digest,
         "runtime_digest" => IR.digest({"release" => ReleaseIdentity.capture(root: File.expand_path("../../..", __dir__)).fetch("content_digest"), "ledger_path" => ledger_path}),
         "grader_digest" => IR.digest(grader),
         "task_digest" => IR.digest({"specification" => SimulatedComparison::SPECIFICATION, "assets" => asset_inventory}),
         "catalog_digest" => IR.digest(manifest.data.fetch("models")),
         "image_digest" => SimulatedComparison::IMAGE.delete_prefix("sha256:"),
         "binary_digest" => SimulatedComparison::EXECUTABLE_DIGEST,
         "relay_digest" => Digest::SHA256.file(File.expand_path("../execution/authorized_provider_relay.cjs", __dir__)).hexdigest,
         "upstream_origin_digest" => Digest::SHA256.hexdigest(origin),
         "route" => "cx/gpt-6-luna-low", "model" => "cx/gpt-6-luna-low"}
      end

      def self.prepare(origin:, assets:, ledger_path:, protocol: "operational")
        {"bindings" => bindings(origin: origin, assets: assets, ledger_path: ledger_path, protocol: protocol), "ledger_path" => canonical_ledger_path(ledger_path), "schedule" => schedule(manifest(protocol: protocol)).map { |cell| cell.merge("seed" => 17000 + cell.fetch("repetition")) },
         "provider_requests_performed" => false, "authorized" => false,
         "required_operator_fields" => %w[limits expires_at quota reviewed_contract reviewed_contract_digest]}
      end

      class CellAdapter
        attr_reader :evidence

        def initialize(launcher_factory:, executor:, evidence:, seconds_per_cell: 600)
          @factory, @executor, @evidence = launcher_factory, executor, evidence
          @seconds_per_cell = seconds_per_cell
        end

        def with_cell(cell)
          raise "provider cell already active" if @launcher
          @cell = cell
          @launcher = @factory.call
          @launcher.start(attempt_id: "cell:#{cell.fetch("id")}", cell_id: cell.fetch("id"), model_profile: "cx/gpt-6-luna-low")
          @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @seconds_per_cell
          yield
        ensure
          if @launcher
            launcher = @launcher
            @launcher = nil
            launcher.close
            @evidence << {"cell_id" => cell.fetch("id"), "audit_records" => launcher.audit_records, "relay_log" => launcher.logs}
          end
        end

        def execute(request)
          raise "provider cell not active" unless @launcher
          remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return AgentRuntime::Result.new(status: "timeout", outputs: {}, error: "authorized cell deadline exhausted") unless remaining.positive?
          request = request.dup
          request.timeout = [request.timeout || remaining, remaining].min
          @executor.call(request, @launcher)
        end
      end

      class Runner < ExperimentRunner
        def initialize(cell_adapter:, expected_manifest: AuthorizedComparison.manifest, **options)
          @cell_adapter = cell_adapter
          @expected_manifest = expected_manifest
          super(**options)
        end

        private

        def ordered_cells(manifest)
          AuthorizedComparison.schedule(manifest)
        end

        def execution_metadata(manifest, cells)
          {"schedule" => {"cell_order" => cells.map { |cell| cell.fetch("id") }, "seeds" => cells.to_h { |cell| [cell.fetch("id"), 17000 + cell.fetch("repetition")] }},
           "schedule_policy" => "frozen-latin-three-by-three", "execution_release_identity" => ReleaseIdentity.capture(root: File.expand_path("../../..", __dir__))}
        end

        def validate_live!(manifest, adapter, authorization)
          raise ArgumentError, "exact nine manifest required" unless manifest.digest == @expected_manifest.digest
          raise ArgumentError, "audited NL2Repo required" unless adapter.instance_of?(Adapters::NL2Repo) && adapter.audited_scoring?
          raise ArgumentError, "authorized cell adapter required" unless authorization.equal?(@cell_adapter)
        end

        def execute_cell(report, cell, adapter)
          @cell_adapter.with_cell(cell) { super }
        rescue => error
          cell["error"] = "#{error.class}: #{error.message}"
          transition(report, cell, "completed", execution_status: "error")
        ensure
          report["provider_evidence"] = @cell_adapter.evidence
          @store.save_report(report)
        end
      end
      private_constant :Runner

      def initialize(launcher_factory: nil, executor: nil)
        @launcher_factory, @executor = launcher_factory, executor
      end

      def run(root:, assets:, destination:, authorization_path:, origin:, credential_file:, ledger_path:, allow_live: false, protocol: "operational")
        raise ArgumentError, "--allow-live-execution required" unless allow_live == true
        authorization = JSON.parse(File.read(authorization_path))
        expected = self.class.bindings(origin: origin, assets: assets, ledger_path: ledger_path, protocol: protocol)
        raise ArgumentError, "authorization bindings changed" unless authorization["bindings"] == expected
        limits = authorization.fetch("limits")
        manifest = self.class.manifest(protocol: protocol)
        if protocol == "compute" && (limits["requests_per_cell"] != 12 || limits["total_tokens_per_cell"] != 384000)
          raise ArgumentError, "compute protocol requires 12 requests and 384000 tokens per cell"
        end
        raise ArgumentError, "cell timeout must match frozen manifest" unless limits["seconds_per_cell"] == manifest.data.fetch("limits").fetch("timeout")
        provider = Execution::AuthorizedProvider.new(reviewed_origin: origin, credential_file: File.expand_path(credential_file), bindings: expected, limits: limits)
        provider.relay_config(authorization: authorization, attempt_id: "preflight", cell_id: "preflight")
        contract = authorization.fetch("reviewed_contract")
        unless contract["version"] == 1 && contract["reviewed"] == true && contract["provider"] == origin &&
            contract["model"] == expected.fetch("model") && contract["evidence"].is_a?(String) && !contract["evidence"].strip.empty? &&
            Digest::SHA256.hexdigest(JSON.generate(contract)) == authorization["reviewed_contract_digest"]
          raise ArgumentError, "reviewed provider contract required"
        end
        quota = authorization.fetch("quota")
        numeric_fields = %w[requests tokens moneyNanos inputTokensPerByte inputTokenOverhead inputPriceNanosPerMillion outputPriceNanosPerMillion expiresAt]
        unless numeric_fields.all? { |key| quota[key].is_a?(Integer) && quota[key].positive? && quota[key] <= 9007199254740991 } &&
            %w[inputTokensPerByte inputTokenOverhead inputPriceNanosPerMillion outputPriceNanosPerMillion].all? { |key| quota[key] == contract[key] } &&
            quota["requests"] == limits["requests_per_cell"] && quota["tokens"] == limits["total_tokens_per_cell"] &&
            quota["moneyNanos"] == limits["money_per_cell"] && quota["expiresAt"] == authorization.fetch("expires_at") * 1000
          raise ArgumentError, "authorized quota invalid"
        end
        caps = {"requests" => limits.fetch("requests_per_cell"), "tokens" => limits.fetch("total_tokens_per_cell"), "money" => limits.fetch("money_per_cell")}
        ledger = Execution::ProviderBudgetLedger.new(path: ledger_path, experiment_digest: manifest.digest,
          cells: manifest.cells.to_h { |cell| [cell.fetch("id"), caps] },
          totals: caps.merge("requests" => caps.fetch("requests") * 9, "tokens" => caps.fetch("tokens") * 9, "money" => limits.fetch("money_per_experiment")), expires_at: authorization.fetch("expires_at"))
        factory = @launcher_factory || -> { Execution::AuthorizedProviderLauncher.new(provider: provider, authorization: authorization, quota: authorization.fetch("quota"), ledger: ledger) }
        evidence = []
        adapter = CellAdapter.new(launcher_factory: factory, executor: @executor || method(:execute), evidence: evidence, seconds_per_cell: limits.fetch("seconds_per_cell"))
        root = File.expand_path(root)
        FileUtils.mkdir_p(root)
        store = Store.new(File.join(root, "store"))
        solvers = {"single-agent" => Solvers::OpenCode.new(live: true, store: store, adapter: adapter),
                   "fixed-workflow" => Solvers::FixedWorkflow.new(live: true, store: store, adapter: adapter),
                   "dsl" => Solvers::ComparativeDSL.new(live: true, store: store, adapter: adapter)}
        grader = NL2RepoAuditedGrader.new(store: store, root: assets)
        benchmark = Adapters::NL2Repo.new(store: store, root: assets, audited_grader: grader)
        raise ArgumentError, "frozen specification mismatch" unless benchmark.load_task("retrying").fetch("specification_digest") == SimulatedComparison::SPECIFICATION
        registry = Registry.new
        registry.register("nl2repo", benchmark)
        runner = Runner.new(cell_adapter: adapter, expected_manifest: manifest, store: store, root: File.join(root, "cells"), registry: registry, solvers: solvers)
        comparison = ComparativeExperiment.new(store: store, runner: runner)
        verification = comparison.run(manifest: manifest, evidence_kind: "live_provider", live_authorization: adapter)
        result = comparison.freeze(experiment_id: manifest.data.fetch("experiment_id"), destination: destination, verification: verification)
        File.write(File.join(destination, "provider-evidence.json"), JSON.pretty_generate(evidence))
        result
      ensure
        if evidence && destination
          FileUtils.mkdir_p(destination)
          File.write(File.join(destination, "provider-evidence.json"), JSON.pretty_generate(evidence))
        end
      end

      def execute(request, launcher)
        helper = File.expand_path("../execution/authorized_loopback_bridge.cjs", __dir__)
        policy = Execution::SandboxRunner::MockRelayPolicy.new(volume: launcher.relay_volume, helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
        sandbox = Execution::SandboxRunner.new(image: SimulatedComparison::IMAGE,
          limits: {"cpus" => 1, "memory_bytes" => 1073741824, "pids" => 128, "tmpfs_bytes" => 134217728}, network_policy: policy)
        launch = Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode", executable_sha256: SimulatedComparison::EXECUTABLE_DIGEST,
          endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: false, transport_mode: "provider_relay")
        AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: sandbox, launch: launch).execute(request)
      end
    end
  end
end
