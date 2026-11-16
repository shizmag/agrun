require "optparse"
require_relative "comparative_experiment"

module AgentRuntime
  module Benchmarks
    class ComparativeCLI
      def run(argv)
        command = argv.shift
        options = {root: ".agru", evidence_kind: "offline_fixture"}
        OptionParser.new do |parser|
          parser.on("--root PATH") { |value| options[:root] = value }
          parser.on("--evidence-kind KIND") { |value| options[:evidence_kind] = value }
          parser.on("--verification PATH") { |value| options[:verification] = value }
          parser.on("--assets PATH") { |value| options[:assets] = value }
          parser.on("--image IMAGE") { |value| options[:image] = value }
          parser.on("--allow-simulated-execution") { options[:allow_simulated] = true }
          parser.on("--allow-live-execution") { options[:allow_live] = true }
          parser.on("--authorization PATH") { |value| options[:authorization_path] = value }
          parser.on("--origin-config PATH") { |value| options[:origin_config] = value }
          parser.on("--credential-file PATH") { |value| options[:credential_file] = value }
          parser.on("--ledger PATH") { |value| options[:ledger_path] = value }
          parser.on("--protocol NAME") { |value| options[:protocol] = value }
        end.parse!(argv)
        result = case command
        when "regrade-freeze"
          require_relative "portable_regrade"
          PortableRegrade.new.run(bundle: argv.fetch(0), root: options.fetch(:root), assets: File.expand_path(options.fetch(:assets, ".agru/nl2repo")), destination: argv[1])
        when "live-prepare", "live-run"
          require_relative "authorized_comparison"
          origin = JSON.parse(File.read(options.fetch(:origin_config))).fetch("reviewed_origin")
          assets = File.expand_path(options.fetch(:assets, ".agru/nl2repo"))
          if command == "live-prepare"
            AuthorizedComparison.prepare(origin: origin, assets: assets, ledger_path: options.fetch(:ledger_path), protocol: options.fetch(:protocol, "operational"))
          else
            AuthorizedComparison.new.run(root: options[:root], assets: assets, destination: argv.fetch(0),
              authorization_path: options.fetch(:authorization_path), origin: origin,
              credential_file: options.fetch(:credential_file), ledger_path: options.fetch(:ledger_path), allow_live: options[:allow_live], protocol: options.fetch(:protocol, "operational"))
          end
        when "plan", "readiness", "run"
          require_relative "simulated_comparison"
          if command == "plan"
            SimulatedComparison.plan(experiment_id: argv.fetch(0, "simulated-comparison"))
          elsif command == "readiness"
            SimulatedComparison.readiness(image: options.fetch(:image, SimulatedComparison::IMAGE))
          else
            raise ArgumentError, "--allow-simulated-execution required" unless options[:allow_simulated]
            SimulatedComparison.new.run(root: options[:root], assets: File.expand_path(options.fetch(:assets, ".agru/nl2repo")),
              destination: argv.fetch(1), experiment_id: argv.fetch(0), image: options.fetch(:image, SimulatedComparison::IMAGE))
          end
        when "verify"
          ComparativeExperiment.verify_freeze(argv.fetch(0))
        when "freeze"
          raise ArgumentError, "--verification PATH required" unless options[:verification]
          store = Store.new(File.expand_path(options[:root]))
          ComparativeExperiment.new(store: store).freeze(experiment_id: argv.fetch(0), destination: argv.fetch(1),
            verification: JSON.parse(File.read(options.fetch(:verification))))
        else
          raise ArgumentError, "expected comparative plan, readiness, run, freeze, verify, regrade-freeze, live-prepare or live-run"
        end
        puts JSON.pretty_generate(result)
        0
      rescue ArgumentError, KeyError, Error, SystemCallError, JSON::ParserError => error
        warn error.message
        1
      ensure
        store&.close if store.respond_to?(:close)
      end
    end
  end
end
