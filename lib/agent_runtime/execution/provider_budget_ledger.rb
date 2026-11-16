require "json"
require "digest"
require "fileutils"
require "securerandom"

module AgentRuntime
  module Execution
    # Trusted-host admission ledger. Reserves whole cell caps, never refunds.
    # Checksums detect corruption, not malicious trusted-host rewriting.
    class ProviderBudgetLedger
      KEYS = %w[requests tokens money].freeze

      def initialize(path:, experiment_digest:, cells:, totals:, expires_at:, wall_clock: -> { Time.now.to_f })
        unless /\A[0-9a-f]{64}\z/.match?(experiment_digest.to_s) && cells.is_a?(Hash) && cells.size == 9 &&
            cells.keys.all? { |key| key.is_a?(String) && !key.empty? } &&
            cells.values.all? { |value| valid_caps?(value) } && valid_caps?(totals) &&
            expires_at.is_a?(Numeric) && expires_at.real? && expires_at.finite?
          raise ArgumentError, "provider_budget_plan_invalid"
        end
        @path = File.expand_path(path)
        @clock = wall_clock
        @plan = JSON.parse(canonical({"experiment_digest" => experiment_digest, "cells" => cells,
                                     "totals" => totals, "expires_at" => expires_at}))
        KEYS.each do |key|
          raise ArgumentError, "provider_budget_plan_exceeds_total" if cells.values.sum { |cap| cap.fetch(key) } > totals.fetch(key)
        end
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        transaction { |state| state }
      end

      # A cell and attempt may each be admitted exactly once, across processes.
      # Return value is evidence only, not a bearer token or security signature.
      def reserve!(cell_id:, attempt_id:)
        unless attempt_id.is_a?(String) && !attempt_id.empty? && attempt_id.bytesize <= 1024
          raise ArgumentError, "provider_budget_attempt_invalid"
        end
        transaction do |state|
          now = @clock.call
          unless now.is_a?(Numeric) && now.real? && now.finite? && now < @plan.fetch("expires_at")
            raise ArgumentError, "provider_budget_expired"
          end
          caps = @plan.fetch("cells").fetch(cell_id) { raise ArgumentError, "provider_budget_cell_unknown" }
          reservations = state.fetch("reservations")
          if reservations.key?(cell_id) || reservations.values.any? { |record| record.fetch("attempt_id") == attempt_id }
            raise ArgumentError, "provider_budget_already_reserved"
          end
          KEYS.each do |key|
            used = reservations.values.sum { |record| record.fetch("caps").fetch(key) }
            raise ArgumentError, "provider_budget_exhausted" if used + caps.fetch(key) > @plan.fetch("totals").fetch(key)
          end
          reservations[cell_id] = {"attempt_id" => attempt_id, "caps" => caps}
          {"experiment_digest" => @plan.fetch("experiment_digest"), "cell_id" => cell_id,
           "attempt_id" => attempt_id, "caps" => caps, "totals" => @plan.fetch("totals"),
           "expires_at" => @plan.fetch("expires_at")}
        end
      end

      private

      def valid_caps?(value)
        value.is_a?(Hash) && value.keys.sort == KEYS.sort && KEYS.all? do |key|
          number = value[key]
          number.is_a?(Numeric) && number.real? && number.finite? && number > 0 &&
            number.is_a?(Integer) && number <= 9_007_199_254_740_991
        end
      end

      def canonical(value)
        normalize = lambda do |item|
          case item
          when Hash then item.keys.sort.to_h { |key| [key, normalize.call(item.fetch(key))] }
          when Array then item.map { |child| normalize.call(child) }
          else item
          end
        end
        JSON.generate(normalize.call(value))
      end

      def transaction
        lock_path = "#{@path}.lock"
        raise ArgumentError, "provider_budget_path_invalid" if File.symlink?(@path) || File.symlink?(lock_path)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          lock.rewind
          marker = lock.read
          unless marker.empty? || marker == "initialized\n"
            raise ArgumentError, "provider_budget_integrity_invalid"
          end
          if marker == "initialized\n" && !File.exist?(@path)
            raise ArgumentError, "provider_budget_integrity_invalid"
          end
          if marker.empty? && !File.exist?(@path)
            lock.write("initialized\n")
            lock.flush
            lock.fsync
          end
          state = if File.exist?(@path)
            envelope = JSON.parse(File.read(@path))
            payload = envelope.fetch("payload")
            unless envelope.keys.sort == %w[checksum payload] &&
                envelope.fetch("checksum") == Digest::SHA256.hexdigest(canonical(payload)) &&
                payload.keys.sort == %w[plan reservations version] && payload["version"] == 1 &&
                payload["plan"] == @plan && payload["reservations"].is_a?(Hash) &&
                payload["reservations"].all? { |cell, record|
                  @plan["cells"].key?(cell) && record.is_a?(Hash) &&
                      record.keys.sort == %w[attempt_id caps] && record["caps"] == @plan["cells"][cell] &&
                      record["attempt_id"].is_a?(String) && !record["attempt_id"].empty?
                } &&
                payload["reservations"].values.map { |record| record["attempt_id"] }.uniq.size == payload["reservations"].size
              raise ArgumentError, "provider_budget_integrity_invalid"
            end
            payload
          else
            {"version" => 1, "plan" => @plan, "reservations" => {}}
          end
          result = yield state
          envelope = {"payload" => state, "checksum" => Digest::SHA256.hexdigest(canonical(state))}
          temporary = "#{@path}.#{SecureRandom.hex(8)}"
          begin
            File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              file.write(canonical(envelope))
              file.flush
              file.fsync
            end
            File.rename(temporary, @path)
            File.open(File.dirname(@path)) { |directory| directory.fsync }
            if marker.empty?
              lock.rewind
              lock.write("initialized\n")
              lock.flush
              lock.fsync
            end
          ensure
            File.unlink(temporary) if File.exist?(temporary)
          end
          result
        end
      rescue JSON::ParserError, KeyError, TypeError
        raise ArgumentError, "provider_budget_integrity_invalid"
      end
    end
  end
end
