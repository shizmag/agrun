require "json"
require "optparse"
require_relative "diagnostics"

module AgentRuntime
  module Tracing
    class CLI
      COMMANDS = %w[list inspect timeline requests tools handoffs diff search verify export import analyze].freeze
      FILTERS = %w[architecture cell stage attempt request tool status kind run experiment parent].freeze

      def initialize(out: $stdout, err: $stderr, store_class: nil)
        @out = out
        @err = err
        @store_class = store_class
      end

      def run(argv)
        args = argv.dup
        args.shift if args.first == "traces"
        command = args.shift
        raise ArgumentError, "expected traces command: #{COMMANDS.join(", ")}" unless COMMANDS.include?(command)
        options = {root: ".agru", filters: {}}
        parser(options).parse!(args)
        raise ArgumentError, "--raw requires --authorize-raw" if options[:raw] && !options[:authorize_raw]
        klass = @store_class || Store
        if command == "import"
          source = options[:source] || args.shift
          raise ArgumentError, "import requires a source" unless source
          raise ArgumentError, "unexpected arguments: #{args.join(" ")}" unless args.empty?
          result = klass.import(source, options[:destination] || options[:root])
          emit(result.respond_to?(:entities) ? {"imported" => true} : result)
          result.close if result.respond_to?(:close)
          return 0
        end
        store = klass.new(options[:root], raw_content: !!options[:raw])
        result = case command
        when "verify" then store.verify
        when "export"
          destination = options[:destination] || args.shift
          raise ArgumentError, "export requires a destination" unless destination
          store.export(destination, include_raw: !!options[:raw])
        when "inspect"
          fetch_entity(store, required_id(options, args))
        when "diff"
          left = fetch_entity(store, required_id(options, args))
          right = fetch_entity(store, options[:to] || args.shift || raise(ArgumentError, "diff requires --to ID"))
          Diagnostics.new([]).diff(left, right)
        else
          filters = options[:filters].dup
          filters["kind"] = {"requests" => "request", "tools" => "tool", "handoffs" => "handoff"}[command] if %w[tools handoffs].include?(command)
          entities = store.entities(filters)
          entities = entities.select { |entity| %w[request llm_request].include?(entity["kind"]) } if command == "requests"
          entities = entities.select { |entity| entity["id"] == options[:id] } if options[:id]
          case command
          when "analyze" then Diagnostics.new(entities).analyze
          when "search"
            query = options[:query] || args.shift || raise(ArgumentError, "search requires a query")
            # Search only the Store's sanitized projection unless explicitly authorized.
            indexed = store.respond_to?(:search) ? store.search(query, filters: filters).map { |entity| entity["id"] } : []
            entities.select { |entity| indexed.include?(entity["id"]) || JSON.generate(search_projection(entity, store, raw: !!options[:raw])).downcase.include?(query.downcase) }
          when "timeline" then entities.sort_by { |entity| [entity["started_at"].to_s, entity["id"].to_s] }
          else entities
          end
        end
        raise ArgumentError, "unexpected arguments: #{args.join(" ")}" unless args.empty?
        emit(result)
        incomplete?(result) ? 1 : 0
      rescue => error
        @err.puts(JSON.generate({"error" => error.message, "type" => error.class.name}))
        1
      ensure
        store.close if defined?(store) && store.respond_to?(:close)
      end

      private

      def parser(options)
        OptionParser.new do |p|
          p.on("--root PATH") { |v| options[:root] = v }
          %w[id to source destination query].each { |key| p.on("--#{key} VALUE") { |v| options[key.to_sym] = v } }
          FILTERS.each do |key|
            p.on("--#{key} VALUE") do |value|
              target = {"cell" => "cell_id", "experiment" => "experiment_id", "run" => "run_id", "parent" => "parent_id"}.fetch(key, key)
              options[:filters][target] = (key == "attempt" && value.match?(/\A[0-9]+\z/)) ? Integer(value, 10) : value
            end
          end
          p.on("--raw") { options[:raw] = true }
          p.on("--include-raw") { options[:raw] = true }
          p.on("--authorize-raw") { options[:authorize_raw] = true }
          p.on("--json") {}
          p.on("--format FORMAT") { |v| raise ArgumentError, "only JSON is supported" unless v == "json" }
        end
      end

      def search_projection(value, store, raw:)
        case value
        when Hash
          if value["digest"] && value["encoding"] == "json+zlib"
            return nil if value["raw"] && !raw
            return nil if value["omitted"]
            return store.read_payload(value, raw: value["raw"] == true)
          end
          value.transform_values { |child| search_projection(child, store, raw: raw) }
        when Array then value.map { |child| search_projection(child, store, raw: raw) }
        else value
        end
      end

      def fetch_entity(store, id)
        store.get(id) || raise(ArgumentError, "unknown trace #{id}")
      end

      def required_id(options, args)
        options[:id] || args.shift || raise(ArgumentError, "command requires --id ID")
      end

      def incomplete?(result)
        return false unless result.is_a?(Hash)
        result["valid"] == false || result["ok"] == false || result["complete"] == false || %w[incomplete corrupt invalid failure].include?(result["status"])
      end

      def emit(result)
        @out.puts(JSON.pretty_generate(result))
      end
    end
  end
end
