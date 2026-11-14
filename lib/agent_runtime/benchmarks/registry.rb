require_relative "adapter"

module AgentRuntime
  module Benchmarks
    class Registry
      def initialize
        @adapters = {}
      end

      def register(name, adapter)
        raise ArgumentError, "benchmark name must be nonempty" unless name.is_a?(String) && !name.empty?
        raise ArgumentError, "benchmark already registered: #{name}" if @adapters.key?(name)
        @adapters[name.dup.freeze] = Adapter.verify!(adapter)
      end

      def fetch(name)
        @adapters.fetch(name)
      end
    end
  end
end
