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
        end.parse!(argv)
        result = case command
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
          raise ArgumentError, "expected comparative freeze EXPERIMENT DIRECTORY or verify DIRECTORY"
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
