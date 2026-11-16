require "json"
require "uri"
require "digest"

module AgentRuntime
  module Execution
    # Authorization/configuration boundary for a reviewed external provider relay.
    # AuthorizedProviderLauncher consumes this without exposing it to the solver.
    # Caller verifies operator consent; equality is not an authenticity signature.
    class AuthorizedProvider
      BINDINGS = %w[experiment_digest runtime_digest grader_digest task_digest catalog_digest
        image_digest binary_digest relay_digest upstream_origin_digest route model].freeze
      LIMITS = %w[requests_per_cell total_tokens_per_cell completion_tokens_per_request
        seconds_per_cell money_per_cell money_per_experiment currency].freeze

      def initialize(reviewed_origin:, credential_file:, bindings:, limits:, wall_clock: -> { Time.now.to_f })
        @origin = reviewed_origin
        validate_origin!
        unless credential_file.is_a?(String) && credential_file.start_with?("/") &&
            !credential_file.include?("\0") && File.file?(credential_file) &&
            !File.symlink?(credential_file) && (File.stat(credential_file).mode & 0o077).zero?
          raise ArgumentError, "authorized_provider_credential_invalid"
        end
        validate_bindings!(bindings)
        validate_limits!(limits)
        @credential_file = credential_file.dup.freeze
        @bindings = snapshot(bindings)
        @limits = snapshot(limits)
        @clock = wall_clock
      end

      # Consent must be verified by the trusted caller; this compares its exact
      # scope, not a signature. The result is trusted-only: never mount it in the
      # solver. No credentials are read and no network/process calls are made.
      def relay_config(authorization:, attempt_id:, cell_id:)
        unless authorization.is_a?(Hash) && (authorization.keys - %w[bindings expires_at limits quota]).empty? &&
            authorization["bindings"] == @bindings && authorization["limits"] == @limits
          raise ArgumentError, "authorized_provider_scope_mismatch"
        end
        expiry = authorization["expires_at"]
        now = @clock.call
        unless finite_number?(expiry) && finite_number?(now) && now < expiry
          raise ArgumentError, "authorized_provider_expired"
        end
        unless [attempt_id, cell_id].all? { |id| id.is_a?(String) && !id.empty? && id.bytesize <= 1024 }
          raise ArgumentError, "authorized_provider_identity_invalid"
        end
        snapshot({"origin" => @origin, "approvedOrigins" => [@origin],
          "credentialFile" => @credential_file, "model" => @bindings.fetch("model"),
          "route" => @bindings.fetch("route"), "timeoutMs" => (@limits.fetch("seconds_per_cell") * 1000).to_i,
          "identity" => {"run_id" => attempt_id, "architecture" => cell_id, "step_id" => cell_id,
                         "attempt" => attempt_id, "attempt_id" => attempt_id, "cell_id" => cell_id},
          "inference" => {"max_completion_tokens" => @limits.fetch("completion_tokens_per_request"),
                          "stream" => true, "stream_options" => {"include_usage" => true}},
          "allowTools" => true})
      end

      private

      def validate_origin!
        uri = URI.parse(@origin)
        unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? &&
            !uri.userinfo && !uri.query && !uri.fragment && uri.path.empty? &&
            @origin == "https://#{uri.host}#{":#{uri.port}" unless uri.port == 443}"
          raise ArgumentError, "authorized_provider_origin_invalid"
        end
        @origin = @origin.dup.freeze
      rescue URI::InvalidURIError, TypeError
        raise ArgumentError, "authorized_provider_origin_invalid"
      end

      def validate_bindings!(bindings)
        unless bindings.is_a?(Hash) && bindings.keys.sort == BINDINGS.sort &&
            bindings.values.all? { |value| value.is_a?(String) && !value.empty? } &&
            (BINDINGS - %w[route model]).all? { |key| /\A[0-9a-f]{64}\z/.match?(bindings[key]) } &&
            bindings["upstream_origin_digest"] == Digest::SHA256.hexdigest(@origin) &&
            bindings["model"] == "cx/gpt-6-luna-low"
          raise ArgumentError, "authorized_provider_bindings_invalid"
        end
      end

      def validate_limits!(limits)
        unless limits.is_a?(Hash) && limits.keys.sort == LIMITS.sort &&
            (LIMITS - %w[currency]).all? { |key| finite_number?(limits[key]) && limits[key] > 0 } &&
            %w[requests_per_cell total_tokens_per_cell completion_tokens_per_request].all? { |key| limits[key].is_a?(Integer) } &&
            limits["completion_tokens_per_request"] <= 32000 && limits["seconds_per_cell"].between?(0.001, 600) &&
            limits["currency"].is_a?(String) && /\A[A-Z]{3}\z/.match?(limits["currency"])
          raise ArgumentError, "authorized_provider_limits_invalid"
        end
      end

      def finite_number?(value)
        value.is_a?(Numeric) && value.real? && value.finite?
      end

      def snapshot(value)
        copy = JSON.parse(JSON.generate(value))
        freeze_value = lambda do |item|
          if item.is_a?(Hash)
            item.each { |key, child|
              key.freeze
              freeze_value.call(child)
            }
          end
          item.each { |child| freeze_value.call(child) } if item.is_a?(Array)
          item.freeze
        end
        freeze_value.call(copy)
      end
    end
  end
end
