require "json"
require "optparse"

module AgentRuntime
  module Benchmarks
    class CLI
      LIMITATIONS = ["Docker must be independently available", "authenticated native collector and official positive/negative controls are not validated", "live providers are disabled"].freeze

      def run(argv)
        command = argv.shift
        if command == "live"
          require_relative "live_cli"
          return LiveCLI.new.run(argv)
        end
        options = {root: ".agru", offline: true, dry_run: false, allow_download: false}
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--offline") { options[:offline] = true }
          parser.on("--dry-run") { options[:dry_run] = true }
          parser.on("--allow-download") { options[:allow_download] = true }
          parser.on("--allow-local-specification-use") { options[:allow_local_specification_use] = true }
          parser.on("--task ID") { |value| options[:task] = value }
          parser.on("--format FORMAT") { |value| options[:format] = value }
          parser.on("--repository PATH") { |value| options[:repository] = value }
          parser.on("--model-catalog PATH") { |value| options[:model_catalog] = value }
          parser.on("--diagnostics") { options[:diagnostics] = true }
          parser.on("--audited-scoring") { options[:audited_scoring] = true }
        end.parse!(argv)
        case command
        when "doctor"
          emit({"offline_default" => true, "official_validation" => "blocked", "ruby" => RUBY_DESCRIPTION,
                "limitations" => LIMITATIONS, "store" => File.expand_path(options[:root])})
        when "plan"
          manifest = read_manifest(argv.fetch(0), catalog_path: options[:model_catalog])
          nl2repo_adapter(Store.new(File.expand_path(options[:root])), options) if options[:audited_scoring]
          emit({"manifest" => manifest.data, "manifest_digest" => manifest.digest, "cells" => manifest.cells,
                "audited_scoring" => audited_metadata(options)})
        when "datasets", "tasks", "prepare"
          require_relative "adapters/nl2repo"
          store = Store.new(File.expand_path(options[:root]))
          adapter = nl2repo_adapter(store, options)
          raise ArgumentError, "unknown benchmark #{argv.first}" if argv.first && argv.first != "nl2repo"
          result = case command
          when "datasets" then {"benchmark" => adapter.identity, "readiness" => adapter.availability}
          when "tasks" then {"benchmark" => adapter.identity, "tasks" => adapter.list_tasks}
          else adapter.prepare(dry_run: options[:dry_run], allow_download: options[:allow_download], task: options[:task], allow_local_specification_use: options.fetch(:allow_local_specification_use, false))
          end
          emit(result.merge("audited_scoring" => audited_metadata(options)))
        when "verify"
          nl2repo_adapter(Store.new(File.expand_path(options[:root])), options) if options[:audited_scoring]
          raise ArgumentError, "unknown benchmark #{argv.first}" unless argv.first == "nl2repo"
          emit({"benchmark" => "nl2repo", "status" => "blocked", "score" => nil,
                "qualification" => "provisional official-benchmark integration",
                "limitations" => LIMITATIONS, "audited_scoring" => audited_metadata(options),
                "controls" => (1..8).to_h { |number| [format("GR-%02d", number), {"status" => "blocked", "reason" => "native isolated validation not established"}] }})
          return 1
        when "report", "compare"
          reports = Reports.new(store: Store.new(File.expand_path(options[:root])))
          if command == "compare"
            emit({"qualification" => "infrastructure-only demonstration", "experiments" => argv.map { |id| reports.summary(experiment_id: id) }})
          else
            case options.fetch(:format, "json")
            when "json" then emit(reports.summary(experiment_id: argv.fetch(0)))
            when "csv", "markdown" then puts reports.render(experiment_id: argv.fetch(0), format: options[:format])
            else raise ArgumentError, "unsupported report format"
            end
          end
        when "run", "regrade"
          store = Store.new(File.expand_path(options[:root]))
          begin
            registry = Registry.new
            registry.register("fixture", FixtureAdapter.new(store: store))
            require_relative "adapters/nl2repo"
            live_regrade = command == "regrade" && store.report(argv.fetch(0)).dig("manifest", "execution_mode") == "live"
            registry.register("nl2repo", nl2repo_adapter(store, options.merge(shared_dataset: live_regrade)))
            runner = ExperimentRunner.new(store: store, root: File.join(store.root, "experiments"), registry: registry,
              solvers: live_regrade ? {} : FixtureSolvers::CATEGORIES.to_h { |id| [id, FixtureSolvers.build(id)] }.merge("repository-submission" => RepositorySolver.new(repository: options[:repository])))
            case command
            when "run"
              result = runner.run(manifest: read_manifest(argv.fetch(0), catalog_path: options[:model_catalog]))
              emit(result.merge("id" => result.fetch("run_id")))
            when "regrade"
              validate_regrade_selection!(store, argv.fetch(0), argv.fetch(1), options)
              result = runner.regrade(experiment_id: argv.fetch(0), cell_id: argv.fetch(1))
              cell = result.fetch("cells").find { |entry| entry.fetch("id") == argv.fetch(1) }
              emit(cell)
            end
          end
        else
          raise ArgumentError, "unknown benchmark command: #{command}"
        end
        0
      rescue ArgumentError, KeyError, Errno::ENOENT, JSON::ParserError, OptionParser::ParseError => error
        warn error.message
        1
      end

      private

      def audited_metadata(options)
        {"enabled" => options.fetch(:audited_scoring, false), "protocol" => options[:audited_scoring] ? "nl2repo-audited-v2" : nil,
         "qualification" => "controlled ordinary submissions only; not authenticated against malicious Python"}
      end

      def nl2repo_adapter(store, options)
        require_relative "adapters/nl2repo"
        root = options[:shared_dataset] ? File.join(Adapters::NL2Repo::ROOT, ".agru", "nl2repo") : File.join(store.root, "nl2repo")
        grader = if options[:audited_scoring]
          require_relative "nl2repo_audited_grader"
          NL2RepoAuditedGrader.new(store: store, root: root)
        end
        Adapters::NL2Repo.new(root: root, store: store, diagnostics: options.fetch(:diagnostics, false), audited_grader: grader)
      end

      def validate_regrade_selection!(store, experiment_id, cell_id, options)
        cell = store.report(experiment_id).fetch("cells").find { |entry| entry.fetch("id") == cell_id }
        raise ArgumentError, "unknown cell #{cell_id}" unless cell
        request = cell.fetch("grading_attempts", []).find { |entry| entry["request"] }&.fetch("request")
        audited = request&.key?("audited_binding")
        raise ArgumentError, "audited regrade requires --audited-scoring" if audited && !options[:audited_scoring]
        if !audited && options[:audited_scoring]
          raise ArgumentError, "cannot change historical grading protocol with --audited-scoring"
        end
      end

      def read_manifest(path, catalog_path: nil)
        require_relative "../execution/model_catalog"
        catalog = Execution::ModelCatalog.new(JSON.parse(File.read(catalog_path))) if catalog_path
        ExperimentManifest.new(JSON.parse(File.read(path)), catalog: catalog)
      end

      def emit(value)
        puts JSON.pretty_generate(value)
      end
    end
  end
end
