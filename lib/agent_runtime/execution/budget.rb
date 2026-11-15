require "digest"
require "securerandom"
require_relative "live_authorization"

module AgentRuntime
  module Execution
    module Budget
      def self.immutable(value)
        case value
        when Hash
          value.to_h { |key, item| [immutable(key), immutable(item)] }.freeze
        when Array
          value.map { |item| immutable(item) }.freeze
        when String
          value.dup.freeze
        else
          value.freeze
        end
      end

      class ModelProfile
        def initialize(id:, provider:, model:, execution_kind:, tool_policy: {})
          fields = {"id" => id, "provider" => provider, "model" => model,
                    "execution_kind" => execution_kind, "tool_policy" => tool_policy}
          unless [id, provider, model].all? { |value| value.is_a?(String) && !value.empty? } &&
              %w[offline_fixture real_provider].include?(execution_kind) && tool_policy.is_a?(Hash)
            raise ArgumentError, "invalid model profile"
          end
          validate_json!(tool_policy)
          @data = Budget.immutable(fields)
          freeze
        end

        def to_h = @data

        private

        def validate_json!(value)
          valid = case value
          when Hash then value.all? { |key, item| key.is_a?(String) && validate_json!(item) }
          when Array then value.all? { |item| validate_json!(item) }
          when String, Integer, TrueClass, FalseClass, NilClass then true
          when Float then value.finite?
          else false
          end
          raise ArgumentError, "profile must contain JSON data" unless valid
          true
        end
      end

      class AdmissionConfig
        def initialize(wall_seconds:, max_concurrent_sessions:, max_attempts: nil, hard_limits: {}, observations: {})
          valid_attempts = max_attempts.nil? || (max_attempts.is_a?(Integer) && max_attempts.positive?)
          unless wall_seconds.is_a?(Numeric) && wall_seconds.real? && wall_seconds.finite? && wall_seconds.positive? && valid_attempts &&
              max_concurrent_sessions.is_a?(Integer) && max_concurrent_sessions.positive?
            raise ArgumentError, "invalid_budget_config: limits must be positive and finite"
          end
          raise ArgumentError, "unsupported_hard_limit" unless hard_limits == {}
          unless observations.is_a?(Hash) && observations.all? { |key, value| %w[cost tokens model tools].include?(key) && [true, false].include?(value) }
            raise ArgumentError, "invalid_budget_config: observations"
          end
          @data = Budget.immutable({"wall_seconds" => wall_seconds.to_f,
            "max_attempts" => max_attempts, "max_concurrent_sessions" => max_concurrent_sessions,
            "hard_limits" => {}, "observations" => observations})
          freeze
        end

        def to_h = @data
      end

      class Scope
        attr_reader :kind, :id, :config, :parent, :started

        def initialize(kind:, id:, config:, parent:, started:)
          @kind, @id, @config, @parent, @started = kind.dup.freeze, id.dup.freeze, config, parent, started
          freeze
        end
      end

      class Decision
        def initialize(data)
          @data = Budget.immutable(data)
          freeze
        end

        def to_h = @data
      end

      class Lease
        attr_reader :decision, :timeout

        def initialize(decision:, timeout:)
          @decision, @timeout = decision, timeout
          freeze
        end
      end

      class Coordinator
        def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @clock = clock
          @mutex = Mutex.new
          @scopes = {}
          @identities = {}
          @attempts = {}
          @leases = {}
        end

        def open_scope(kind:, id:, config:, parent: nil)
          @mutex.synchronize do
            raise ArgumentError, "foreign parent scope" if parent && !@scopes.key?(parent)
            expected = {"pool" => nil, "experiment" => (parent&.kind == "pool") ? "pool" : nil,
                        "run" => "experiment", "attempt" => "run"}
            valid = expected.key?(kind) && id.is_a?(String) && !id.empty? && config.is_a?(AdmissionConfig) &&
              parent&.kind == expected[kind] && (!parent || !@scopes.fetch(parent)[:closed])
            unless valid
              raise ArgumentError, "invalid scope hierarchy"
            end
            identity = [parent, kind, id]
            raise ArgumentError, "duplicate scope identity" if @identities.key?(identity)
            if kind == "attempt" && config.to_h.values_at("max_attempts", "max_concurrent_sessions") != [1, 1]
              raise ArgumentError, "attempt scope limits must be one"
            end
            scope = Scope.new(kind: kind, id: id, config: config, parent: parent, started: now)
            @scopes[scope] = {attempts: 0, active: 0, closed: false}
            @identities[identity] = scope
            scope
          end
        end

        def close_scope(scope:)
          @mutex.synchronize do
            state = @scopes.fetch(scope) { raise ArgumentError, "foreign scope" }
            if state[:active].positive? || @scopes.any? { |child, entry| child.parent.equal?(scope) && !entry[:closed] }
              raise ArgumentError, "scope still active"
            end
            state[:closed] = true
          end
          nil
        end

        def admit(scopes:, profile:, request:, executable:, executable_sha256:, authorization: nil, authorization_scope: nil)
          validate_request!(request, profile, executable, executable_sha256)
          digest = Digest::SHA256.hexdigest(IR.dump(profile.to_h))
          live = profile.to_h.fetch("execution_kind") == "real_provider"
          grant = live ? nil : authorization&.call(profile: profile, request: request,
            executable: executable, executable_sha256: executable_sha256)
          outcome = @mutex.synchronize do
            validate_chain!(scopes, request)
            live_reason = nil
            if live
              grant, live_reason = live_grant(authorization, authorization_scope, profile, scopes)
            end
            reserve(scopes, profile, request, executable, executable_sha256, digest, grant, live_reason)
          end
          begin
            yield(outcome.is_a?(Lease) ? outcome.decision : outcome) if block_given?
          # Release on asynchronous Timeout/Interrupt too; never swallow it.
          rescue Exception # standard:disable Lint/RescueException
            release(lease: outcome) if outcome.is_a?(Lease)
            raise
          end
          outcome
        end

        def remaining_timeout(lease:)
          @mutex.synchronize do
            entry = @leases.fetch(lease) { raise ArgumentError, "foreign lease" }
            raise ArgumentError, "released lease" if entry[:released]
            current = now
            remaining = ([entry[:deadline] - current] + entry[:scopes].map { |scope| deadline(scope) - current }).min
            remaining.positive? ? remaining : nil
          end
        end

        def release(lease:)
          @mutex.synchronize do
            entry = @leases.fetch(lease) { raise ArgumentError, "foreign lease" }
            unless entry[:released]
              entry[:scopes].each { |scope| @scopes.fetch(scope)[:active] -= 1 }
              entry[:released] = true
            end
          end
          nil
        end

        private

        def now
          value = @clock.call
          raise ArgumentError, "clock must be finite" unless value.is_a?(Numeric) && value.finite?
          value.to_f
        end

        def deadline(scope) = scope.started + scope.config.to_h.fetch("wall_seconds")

        def validate_request!(request, profile, executable, sha)
          unless profile.is_a?(ModelProfile) && [request.run_id, request.step_id].all? { |id| id.is_a?(String) && !id.empty? } &&
              request.attempt.is_a?(Integer) && request.attempt.positive? &&
              request.timeout.is_a?(Numeric) && request.timeout.real? && request.timeout.finite? && request.timeout.positive? &&
              executable.is_a?(String) && executable.start_with?("/") && File.expand_path(executable) == executable &&
              sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/)
            raise ArgumentError, "invalid admission input"
          end
        end

        def validate_chain!(scopes, request)
          unless scopes.is_a?(Array) && scopes.all? { |scope| scope.is_a?(Scope) } &&
              [%w[experiment run attempt], %w[pool experiment run attempt]].include?(scopes.map(&:kind)) &&
              scopes.all? { |scope| @scopes.key?(scope) && !@scopes.fetch(scope)[:closed] } &&
              scopes.each_with_index.all? { |scope, index| scope.parent.equal?(index.zero? ? nil : scopes[index - 1]) } &&
              scopes[-2].id == request.run_id && scopes[-1].id == "#{request.step_id}:#{request.attempt}"
            raise ArgumentError, "invalid admission scope chain"
          end
        end

        def live_grant(authorization, scope, profile, scopes)
          return [nil, "real_provider_disabled"] unless authorization.instance_of?(LiveAuthorization)
          begin
            grant = authorization.preflight!(scope: scope,
              hard_limits: scopes.map { |item| item.config.to_h.fetch("hard_limits") }.reduce({}, :merge))
            expected = profile.to_h.values_at("provider", "model")
            return [nil, "authorization_mismatch"] unless scope.values_at("provider", "model") == expected
            [grant, nil]
          rescue ArgumentError
            [nil, "authorization_mismatch"]
          end
        end

        def reserve(scopes, profile, request, executable, sha, digest, grant, live_reason = nil)
          current = now
          experiment = scopes.find { |scope| scope.kind == "experiment" }
          key = [request.run_id, request.step_id, request.attempt]
          live = profile.to_h.fetch("execution_kind") == "real_provider"
          reason = if live_reason
            live_reason
          elsif grant.nil?
            "authorization_required"
          elsif !live && (!grant.is_a?(Hash) || grant.values_at("mode", "executable", "sha256", "profile_digest", "experiment_id", "run_id") !=
              ["offline_fixture", executable, sha, digest, experiment.id, request.run_id])
            "authorization_mismatch"
          elsif @attempts.key?(key)
            "duplicate_attempt"
          end
          snapshots = scopes.map do |scope|
            state = @scopes.fetch(scope)
            {"kind" => scope.kind, "id" => scope.id, "limits" => scope.config.to_h,
             "elapsed_seconds" => current - scope.started, "remaining_wall_seconds" => [deadline(scope) - current, 0].max,
             "attempts_before" => state[:attempts], "attempts_after" => state[:attempts],
             "active_before" => state[:active], "active_after" => state[:active]}
          end
          denied_scope = nil
          unless reason
            snapshots.each do |snapshot|
              limits = snapshot.fetch("limits")
              reason = if snapshot.fetch("remaining_wall_seconds") <= 0
                "wall_exhausted"
              elsif limits.fetch("max_attempts") && snapshot.fetch("attempts_before") >= limits.fetch("max_attempts")
                "attempts_exhausted"
              elsif snapshot.fetch("active_before") >= limits.fetch("max_concurrent_sessions")
                "concurrency_exhausted"
              end
              if reason
                denied_scope = snapshot.slice("kind", "id")
                break
              end
            end
          end
          allowed = reason.nil?
          timeout = allowed ? ([request.timeout.to_f] + snapshots.map { |item| item.fetch("remaining_wall_seconds") }).min : nil
          if allowed
            scopes.zip(snapshots).each do |scope, snapshot|
              state = @scopes.fetch(scope)
              snapshot["attempts_after"] = state[:attempts] += 1
              snapshot["active_after"] = state[:active] += 1
            end
            @attempts[key] = true
          end
          auth = grant.is_a?(Hash) ? grant.slice("mode", "experiment_id", "run_id") : {}
          auth = {"mode" => "none", "experiment_id" => nil, "run_id" => nil}.merge(auth)
          if live && grant
            auth = grant.merge("mode" => "live", "experiment_id" => experiment.id, "run_id" => request.run_id,
              "executable" => executable, "sha256" => sha, "profile_digest" => digest)
          end
          decision = Decision.new({"schema_version" => 1, "decision_id" => SecureRandom.uuid,
            "allowed" => allowed, "reason" => reason || "admitted", "denied_scope" => denied_scope,
            "run_id" => request.run_id, "step_id" => request.step_id, "attempt" => request.attempt,
            "profile_digest" => digest, "authorization" => auth,
            "effective_timeout_seconds" => timeout, "scopes" => snapshots})
          return decision unless allowed
          lease = Lease.new(decision: decision, timeout: timeout)
          @leases[lease] = {scopes: scopes.dup.freeze, deadline: current + request.timeout, released: false}
          lease
        end
      end
    end
  end
end
