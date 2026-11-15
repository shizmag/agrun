require "uri"

module AgentRuntime
  module Execution
    # Trusted local consent, not a security sandbox or provider spending limit.
    class LiveAuthorization
      FIELDS = %w[experiment_digest task solver provider endpoint route model mode].freeze

      def initialize(scope:, expires_at:, financial_exposure:, wall_clock: -> { Time.now.to_f })
        validate_scope!(scope)
        unless expires_at.is_a?(Numeric) && expires_at.real? && expires_at.finite?
          raise ArgumentError, "authorization_expiry_invalid"
        end
        unless financial_exposure == "not_hard_bounded"
          raise ArgumentError, "authorization_financial_exposure_required"
        end
        @scope = scope.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze
        @clock = wall_clock
        @data = {"scope" => @scope, "expires_at" => expires_at.to_f,
                 "financial_exposure" => "not_hard_bounded".freeze}.freeze
        freeze
      end

      def to_h = @data

      def preflight!(scope:, hard_limits: {})
        validate_scope!(scope)
        raise ArgumentError, "authorization_scope_mismatch" unless scope == @scope
        raise ArgumentError, "unsupported_hard_limit" unless hard_limits == {}
        now = @clock.call
        unless now.is_a?(Numeric) && now.real? && now.finite?
          raise ArgumentError, "authorization_clock_invalid"
        end
        raise ArgumentError, "authorization_expired" if now >= @data.fetch("expires_at")
        @data
      end

      private

      def validate_scope!(scope)
        unless scope.is_a?(Hash) && scope.keys.all? { |key| key.is_a?(String) } && scope.keys.sort == FIELDS.sort &&
            scope.values.all? { |value| value.is_a?(String) && !value.empty? } &&
            scope.fetch("experiment_digest").match?(/\A[0-9a-f]{64}\z/)
          raise ArgumentError, "authorization_scope_invalid"
        end
        uri = URI.parse(scope.fetch("endpoint"))
        unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise ArgumentError, "authorization_endpoint_invalid"
        end
      rescue URI::InvalidURIError
        raise ArgumentError, "authorization_endpoint_invalid"
      end
    end
  end
end
