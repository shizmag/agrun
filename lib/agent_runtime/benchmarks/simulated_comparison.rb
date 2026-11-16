require_relative "experiment_runner"
require_relative "comparative_solvers"
require_relative "registry"
require_relative "nl2repo_audited_grader"
require_relative "../execution/sandbox_runner"
require_relative "../adapters/sandbox_open_code_cli"
require_relative "comparative_experiment"
require_relative "../execution/simulated_provider"

module AgentRuntime
  module Benchmarks
    # The frozen mock helper has no internet-facing upstream: both agent and
    # relay containers use --network=none. This is infrastructure evidence only.
    class SimulatedComparison
      IMAGE = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1".freeze
      EXECUTABLE_DIGEST = "5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0".freeze
      SPECIFICATION = "cd41306283b97f81d9cb8ec14985b47acf973dea92f492b53a4e1aaa796a4168".freeze

      # The controlled exception is private to this assembled runner. Callers
      # cannot register arbitrary offline solvers or replace its registry.
      class Runner < ExperimentRunner
        def initialize(mock_solvers:, **options)
          @mock_solvers = mock_solvers
          super(**options, solvers: mock_solvers)
        end

        private

        def execute_cell(report, cell, adapter)
          File.write(File.join(File.dirname(@root), "active-cell.json"), JSON.generate("cell_id" => cell.fetch("id")))
          super
        end

        def ordered_cells(manifest)
          random = Random.new(20261116)
          order = manifest.data.fetch("solver_ids").shuffle(random: random)
          manifest.cells.group_by { |cell| cell.fetch("repetition") }.sort.each_with_index.flat_map do |(_, cells), index|
            order.rotate(index).map { |id| cells.find { |cell| cell.fetch("solver_id") == id } }
          end
        end

        def execution_metadata(manifest, cells)
          {"execution_release_identity" => ReleaseIdentity.capture(root: File.expand_path("../../..", __dir__)),
           "schedule" => {"kind" => "seeded_latin_square", "seed" => 20261116, "cell_order" => cells.map { |cell| cell.fetch("id") }}}
        end

        def validate_offline!(config, adapter)
          raise ArgumentError, "simulated comparison requires audited NL2Repo" unless adapter.instance_of?(Adapters::NL2Repo) && adapter.audited_scoring?
          raise ArgumentError, "simulated comparison manifest mismatch" unless config["execution_mode"] == "offline" && config.fetch("solver_ids") == @mock_solvers.keys && config.fetch("benchmark").fetch("task_ids") == ["retrying"]
          raise ArgumentError, "simulated comparison requires frozen model" unless config.fetch("models") == [{"id" => "cx/gpt-6-luna-low", "served_by" => "controlled_https_simulator"}]
        end
      end
      private_constant :Runner

      class AttemptAdapter
        def initialize(root:, image:, evidence:)
          @root, @image, @evidence = root, image, evidence
        end

        def execute(request)
          attempt_id = "#{request.run_id}:#{request.step_id}:#{request.attempt}"
          report_path = File.join(@root, "active-cell.json")
          cell_id = File.file?(report_path) ? JSON.parse(File.read(report_path)).fetch("cell_id") : request.run_id
          provider = Execution::SimulatedProvider.new
          provider.start(attempt_id: attempt_id, cell_id: cell_id, model_profile: "cx/gpt-6-luna-low")
          helper = File.expand_path("../execution/loopback_bridge.cjs", __dir__)
          policy = Execution::SandboxRunner::MockRelayPolicy.new(volume: provider.relay_volume, helper: helper, helper_sha256: Digest::SHA256.file(helper).hexdigest)
          sandbox = Execution::SandboxRunner.new(image: @image,
            limits: {"cpus" => 1, "memory_bytes" => 1073741824, "pids" => 128, "tmpfs_bytes" => 134217728}, network_policy: policy)
          launch = Execution::SandboxOpenCodeLaunch.new(executable: "/usr/local/bin/opencode", executable_sha256: EXECUTABLE_DIGEST,
            endpoint: "http://127.0.0.1:18080/v1", model: "mock/cx/gpt-6-luna-low", provider: "mock", wire_model: "cx/gpt-6-luna-low", mock_only: false, transport_mode: "provider_relay")
          AgentRuntime::Adapters::SandboxOpenCodeCLI.new(runner: sandbox, launch: launch).execute(request)
        ensure
          if provider
            begin
              logs = provider.logs("relay")
              @evidence << {"attempt_id" => attempt_id, "cell_id" => cell_id, "runtime_run_id" => request.run_id, "relay_log" => logs, "relay_log_sha256" => Digest::SHA256.hexdigest(logs)}
            ensure
              provider.close
            end
          end
        end
      end

      def self.plan(experiment_id: "simulated-comparison")
        {"schema_version" => 1, "experiment_id" => experiment_id,
         "benchmark" => {"name" => "nl2repo", "revision" => "781a1da1ee41fb8edb0bed22f586d69111610edf", "task_ids" => ["retrying"]},
         "solver_ids" => %w[single-agent fixed-workflow dsl], "models" => [{"id" => "cx/gpt-6-luna-low", "served_by" => "controlled_https_simulator"}],
         "repetitions" => 3, "limits" => {"timeout" => 120}, "execution_mode" => "offline", "subset_role" => "development"}
      end

      def self.readiness(image: IMAGE)
        result = AgentRuntime::Adapters::ProcessRunner.new.call(argv: ["docker", "image", "inspect", image], cwd: Dir.pwd, timeout: 15)
        {"ready" => result["status"] == "success", "image" => image, "provider_requests_performed" => false,
         "evidence_kind" => "simulated_relay", "error" => result["stderr"]}
      end

      def run(root:, assets:, destination:, experiment_id: "simulated-comparison", image: IMAGE)
        root = File.expand_path(root)
        FileUtils.mkdir_p(root)
        store = Store.new(File.join(root, "store"))
        evidence = []
        adapter = AttemptAdapter.new(root: root, image: image, evidence: evidence)
        solvers = {"single-agent" => Solvers::OpenCode.new(live: true, store: store, adapter: adapter),
                   "fixed-workflow" => Solvers::FixedWorkflow.new(live: true, store: store, adapter: adapter),
                   "dsl" => Solvers::ComparativeDSL.new(live: true, store: store, adapter: adapter)}
        grader = NL2RepoAuditedGrader.new(store: store, root: assets)
        benchmark = Adapters::NL2Repo.new(store: store, root: assets, audited_grader: grader)
        raise ArgumentError, "frozen specification mismatch" unless benchmark.load_task("retrying").fetch("specification_digest") == SPECIFICATION
        registry = Registry.new
        registry.register("nl2repo", benchmark)
        manifest = self.class.plan(experiment_id: experiment_id)
        manifest.fetch("benchmark")["revision"] = benchmark.identity.fetch("revision")
        runner = Runner.new(store: store, root: File.join(root, "runs"), registry: registry, mock_solvers: solvers)
        runner.run(manifest: manifest)
        report = store.report(experiment_id)
        report["evidence_kind"] = "simulated_relay"
        report["simulation"] = {"transport" => "controlled_https", "image" => image, "paid_provider_calls" => false, "attempts" => evidence}
        store.save_report(report)
        experiment = ComparativeExperiment.new(store: store, runner: runner)
        verification = experiment.verify_regrades(experiment_id: experiment_id, evidence_kind: "simulated_relay")
        File.write(File.join(root, "verification.json"), JSON.pretty_generate(verification))
        require_relative "scientific_report"
        File.write(File.join(root, "report.md"), ScientificReport.new(store: store).render(experiment_id: experiment_id, evidence_kind: "simulated_relay"))
        experiment.freeze(experiment_id: experiment_id, destination: destination, verification: verification)
      ensure
        store&.close if store.respond_to?(:close)
      end
    end
  end
end
