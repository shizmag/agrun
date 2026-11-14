require "json"
require "optparse"

module AgentRuntime
  module Benchmarks
    class CLI
      LIMITATIONS = ["Docker must be independently available", "authenticated native collector and official positive/negative controls are not validated", "live providers are disabled"].freeze

      def run(argv)
        command = argv.shift
        options = {root: ".agru", offline: true, dry_run: false, allow_download: false}
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--offline") { options[:offline] = true }
          parser.on("--dry-run") { options[:dry_run] = true }
          parser.on("--allow-download") { options[:allow_download] = true }
          parser.on("--format FORMAT") { |value| options[:format] = value }
        end.parse!(argv)
        case command
        when "doctor"
          emit({"offline_default" => true, "official_validation" => "blocked", "ruby" => RUBY_DESCRIPTION,
                "limitations" => LIMITATIONS, "store" => File.expand_path(options[:root])})
        when "plan"
          manifest = read_manifest(argv.fetch(0))
          emit({"manifest" => manifest.data, "manifest_digest" => manifest.digest, "cells" => manifest.cells})
        when "datasets", "tasks", "prepare"
          require_relative "adapters/nl2repo"
          adapter = Adapters::NL2Repo.new(root: File.join(File.expand_path(options[:root]), "nl2repo"))
          raise ArgumentError, "unknown benchmark #{argv.first}" if argv.first && argv.first != "nl2repo"
          result = case command
          when "datasets" then {"benchmark" => adapter.identity, "readiness" => adapter.availability}
          when "tasks" then {"benchmark" => adapter.identity, "tasks" => adapter.list_tasks}
          else adapter.prepare(dry_run: options[:dry_run], allow_download: options[:allow_download])
          end
          emit(result)
        when "verify"
          raise ArgumentError, "unknown benchmark #{argv.first}" unless argv.first == "nl2repo"
          emit({"benchmark" => "nl2repo", "status" => "blocked", "score" => nil,
                "qualification" => "provisional official-benchmark integration",
                "limitations" => LIMITATIONS,
                "controls" => (1..8).to_h { |number| [format("GR-%02d", number), {"status" => "blocked", "reason" => "native isolated validation not established"}] }})
          return 1
        when "run", "report", "regrade", "compare"
          store = Store.new(File.expand_path(options[:root]))
          begin
            registry = Registry.new
            registry.register("fixture", FixtureAdapter.new(store: store))
            runner = ExperimentRunner.new(store: store, root: File.join(store.root, "experiments"), registry: registry,
              solvers: FixtureSolvers::CATEGORIES.to_h { |id| [id, FixtureSolvers.build(id)] })
            reports = Reports.new(store: store)
            case command
            when "run"
              result = runner.run(manifest: read_manifest(argv.fetch(0)))
              emit(result.merge("id" => result.fetch("run_id")))
            when "report"
              case options.fetch(:format, "json")
              when "json" then emit(reports.summary(experiment_id: argv.fetch(0)))
              when "csv", "markdown" then puts reports.render(experiment_id: argv.fetch(0), format: options[:format])
              else raise ArgumentError, "unsupported report format"
              end
            when "regrade"
              result = runner.regrade(experiment_id: argv.fetch(0), cell_id: argv.fetch(1))
              cell = result.fetch("cells").find { |entry| entry.fetch("id") == argv.fetch(1) }
              emit(cell)
            when "compare"
              emit({"qualification" => "infrastructure-only demonstration", "experiments" => argv.map { |id| reports.summary(experiment_id: id) }})
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

      def read_manifest(path)
        ExperimentManifest.new(JSON.parse(File.read(path)))
      end

      def emit(value)
        puts JSON.pretty_generate(value)
      end
    end
  end
end
