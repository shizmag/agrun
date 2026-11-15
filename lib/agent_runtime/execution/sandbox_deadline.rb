module AgentRuntime
  module Execution
    # One monotonic budget shared by every sandbox lifecycle phase. Callers must
    # pass remaining! to blocking operations and check! inside copying loops;
    # this object does not interrupt an already blocked operation by itself.
    class SandboxDeadline
      class Exceeded < StandardError
        attr_reader :status, :phase

        def initialize(status:, phase:)
          @status = status
          @phase = phase
          super("sandbox #{status} during #{phase}")
        end
      end

      def initialize(timeout:, cancellation: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @cancellation = cancellation
        @expires_at = @clock.call + positive_limit(timeout)
      end

      def remaining!(phase:, cap: nil)
        limit = positive_limit(cap) unless cap.nil?
        raise Exceeded.new(status: "cancelled", phase: phase) if @cancellation&.cancelled?
        remaining = @expires_at - @clock.call
        raise Exceeded.new(status: "timeout", phase: phase) unless remaining.positive?
        limit ? [remaining, limit].min : remaining
      end

      def check!(phase:)
        remaining!(phase: phase)
        nil
      end

      # Cleanup is an explicit exception to the request deadline. It is bounded,
      # cancellation-independent, and memoized so successive cleanup operations
      # cannot accidentally receive fresh budgets. Never use it for export.
      def emergency_cleanup(timeout:)
        positive_limit(timeout)
        @emergency_cleanup ||= self.class.new(timeout: timeout, clock: @clock)
      end

      private

      def positive_limit(value)
        limit = Float(value)
        raise ArgumentError, "timeout must be positive and finite" unless limit.positive? && limit.finite?
        limit
      end
    end
  end
end
