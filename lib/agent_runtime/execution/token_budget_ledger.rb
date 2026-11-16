require "json"
require "digest"
require "fileutils"

module AgentRuntime
  module Execution
    # Trusted-host, token-only admission accounting; no prices or tokenizer claims.
    # Keep this same path for the entire authorization, across all executions.
    # Checksums detect accidents, not malicious trusted-host rewriting/deletion.
    class TokenBudgetLedger
      MAX_TOKENS = 1_000_000_000
      MODEL = "cx/gpt-6-luna-low"

      def initialize(path:, intent_digest:, total_tokens:, model: MODEL)
        unless /\A[0-9a-f]{64}\z/.match?(intent_digest.to_s) &&
            total_tokens.is_a?(Integer) && total_tokens.between?(1, MAX_TOKENS) && model == MODEL
          raise ArgumentError, "token_budget_authorization_invalid"
        end
        @path = File.expand_path(path)
        @plan = {"path" => @path, "intent_digest" => intent_digest,
                 "total_tokens" => total_tokens, "model" => model, "version" => 1}
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        transaction { |_events| nil }
      end

      # The trusted gateway supplies its conservative input allowance plus the
      # enforced completion cap. Neither is a provider/tokenizer guarantee.
      def begin_request(request_id:, cell_id:, attempt_id:, input_tokens:, completion_tokens:, model: MODEL)
        unless [request_id, cell_id, attempt_id].all? { |v| v.is_a?(String) && !v.empty? && v.bytesize <= 1024 } &&
            [input_tokens, completion_tokens].all? { |v| v.is_a?(Integer) && v.between?(1, MAX_TOKENS) } && model == @plan["model"]
          raise ArgumentError, "token_budget_request_invalid"
        end
        transaction do |events|
          raise ArgumentError, "token_budget_halted" unless unresolved_violations(events).empty?
          reservations = events.select { |e| e["type"] == "reserve" }
          raise ArgumentError, "token_budget_request_duplicate" if reservations.any? { |e| e["request_id"] == request_id }
          tokens = input_tokens + completion_tokens
          if reservations.sum { |e| e.fetch("reserved_tokens") } + tokens > @plan["total_tokens"]
            raise ArgumentError, "token_budget_exhausted"
          end
          event = {"type" => "reserve", "request_id" => request_id, "cell_id" => cell_id,
                   "attempt_id" => attempt_id, "model" => model, "input_tokens" => input_tokens,
                   "completion_tokens" => completion_tokens, "reserved_tokens" => tokens}
          events << event
          event.dup
        end
      end
      alias_method :reserve!, :begin_request

      # Trusted reporter only. nil usage remains unknown and retains the entire
      # reservation. Even known smaller usage never refunds admission capacity.
      def settle(request_id:, observed_model:, usage:, reporter:)
        valid_usage = valid_usage?(usage)
        valid_model = observed_model.nil? || (observed_model.is_a?(String) && observed_model.bytesize <= 1024)
        unless reporter.is_a?(String) && !reporter.empty? && reporter.bytesize <= 1024 && valid_model &&
            valid_usage
          raise ArgumentError, "token_budget_usage_invalid"
        end
        result = transaction do |events|
          reservation = events.find { |e| e["type"] == "reserve" && e["request_id"] == request_id }
          raise ArgumentError, "token_budget_request_unknown" unless reservation
          raise ArgumentError, "token_budget_already_settled" if events.any? { |e| e["type"] == "settle" && e["request_id"] == request_id }
          violation = if usage && (usage["prompt_tokens"] > reservation["input_tokens"] || usage["completion_tokens"] > reservation["completion_tokens"])
            "token_budget_usage_exceeds_reservation"
          elsif observed_model && ![@plan["model"], "gpt-6-luna"].include?(observed_model)
            "token_budget_model_name_mismatch_not_attestation"
          end
          event = {"type" => "settle", "request_id" => request_id, "observed_model" => observed_model,
                   "usage" => usage, "reporter" => reporter, "violation" => violation,
                   "model_identity" => observed_model.nil? ? "unknown" : "unattested",
                   "model_name_matches_request" => observed_model.nil? ? nil : observed_model == @plan["model"]}
          events << event
          event.dup
        end
        raise ArgumentError, result["violation"] if result["violation"]
        result
      end
      alias_method :settle!, :settle

      # Explicit trusted-host review only. This acknowledges an updated heartbeat
      # contract, not proof of the historical event's model or event structure.
      def resolve_identity_halt!(request_id:, evidence_digest:, reason:)
        unless /\A[0-9a-f]{64}\z/.match?(evidence_digest.to_s) &&
            reason == "source_verified_heartbeat_contract_updated"
          raise ArgumentError, "token_budget_resolution_invalid"
        end
        transaction do |events|
          violation = unresolved_violations(events).find { |event| event["request_id"] == request_id }
          unless violation && violation["violation"] == "token_budget_model_name_mismatch_not_attestation"
            raise ArgumentError, "token_budget_resolution_not_identity_halt"
          end
          record = {"type" => "resolve_identity_halt", "request_id" => request_id,
                    "evidence_digest" => evidence_digest, "reason" => reason}
          events << record
          record.dup
        end
      end

      # Provider response names are observations, not independent route proof.
      def snapshot
        transaction do |events|
          reservations = events.select { |e| e["type"] == "reserve" }
          settlements = events.select { |e| e["type"] == "settle" }
          known = settlements.filter_map { |e| e["usage"] }
          {"total_tokens" => @plan["total_tokens"],
           "reserved_tokens" => reservations.sum { |e| e["reserved_tokens"] },
           "request_count" => reservations.length,
           "known_usage_tokens" => known.sum { |usage| usage.fetch("prompt_tokens") + usage.fetch("completion_tokens") },
           "unknown_usage_count" => reservations.length - known.length,
           "unknown_model_count" => reservations.length - settlements.count { |e| e["observed_model"] },
           "unresolved_violations" => unresolved_violations(events).map(&:dup),
           "halted" => !unresolved_violations(events).empty?}
        end
      end

      private

      def unresolved_violations(events)
        resolved = events.select { |event| event["type"] == "resolve_identity_halt" }.map { |event| event["request_id"] }
        events.select do |event|
          event["violation"] && !(event["violation"] == "token_budget_model_name_mismatch_not_attestation" && resolved.include?(event["request_id"]))
        end
      end

      def valid_usage?(usage)
        return true if usage.nil?
        return false unless usage.is_a?(Hash)
        allowed = %w[prompt_tokens completion_tokens total_tokens prompt_tokens_details completion_tokens_details]
        return false unless (usage.keys - allowed).empty?
        return false unless %w[prompt_tokens completion_tokens].all? { |key| nonnegative_integer?(usage[key]) }
        total = usage["prompt_tokens"] + usage["completion_tokens"]
        return false unless usage["total_tokens"].nil? || usage["total_tokens"] == total
        details = {"prompt_tokens_details" => %w[cached_tokens audio_tokens],
                   "completion_tokens_details" => %w[reasoning_tokens audio_tokens accepted_prediction_tokens rejected_prediction_tokens]}
        details.all? do |key, fields|
          value = usage[key]
          value.nil? || (value.is_a?(Hash) && (value.keys - fields).empty? &&
            value.values.all? { |count| count.nil? || nonnegative_integer?(count) })
        end
      end

      def nonnegative_integer?(value)
        value.is_a?(Integer) && value >= 0
      end

      # One append-only inode is both lock and log. Torn writes fail closed on
      # restart. Exclusive creation prevents silently resetting an existing log.
      def transaction
        raise ArgumentError, "token_budget_path_invalid" if File.symlink?(@path)
        created = false
        file = begin
          f = File.open(@path, File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
          created = true
          f
        rescue Errno::EEXIST
          File.open(@path, File::RDWR | File::NOFOLLOW)
        end
        file.flock(File::LOCK_EX)
        unless file.stat.file? && file.stat.nlink == 1 && file.stat.uid == Process.uid &&
            (file.stat.mode & 0o777) == 0o600 && File.stat(@path).ino == file.stat.ino
          raise ArgumentError, "token_budget_path_invalid"
        end
        text = file.read
        if text.empty?
          raise ArgumentError, "token_budget_integrity_invalid" unless created
          append(file, @plan, "0" * 64)
          File.open(File.dirname(@path)) { |directory| directory.fsync }
          file.rewind
          text = file.read
        end
        raise ArgumentError, "token_budget_integrity_invalid" unless text.end_with?("\n")
        previous = "0" * 64
        records = text.lines.map do |line|
          envelope = JSON.parse(line)
          data = envelope.fetch("data")
          checksum = Digest::SHA256.hexdigest(previous + JSON.generate(data))
          unless envelope.keys.sort == %w[checksum data] && envelope["checksum"] == checksum
            raise ArgumentError, "token_budget_integrity_invalid"
          end
          previous = checksum
          data
        end
        raise ArgumentError, "token_budget_authorization_mismatch" unless records.shift == @plan
        before = records.length
        result = yield records
        records.drop(before).each { |event| previous = append(file, event, previous) }
        result
      rescue JSON::ParserError, KeyError, TypeError
        raise ArgumentError, "token_budget_integrity_invalid"
      ensure
        file&.close
      end

      def append(file, data, previous)
        checksum = Digest::SHA256.hexdigest(previous + JSON.generate(data))
        file.seek(0, IO::SEEK_END)
        file.write(JSON.generate({"data" => data, "checksum" => checksum}) + "\n")
        file.flush
        file.fsync
        checksum
      end
    end
  end
end
