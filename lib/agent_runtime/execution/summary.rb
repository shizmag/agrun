module AgentRuntime
  module Execution
    # Read-only projections of immutable attempt logs. Copied SQLite summaries
    # and adapter-supplied usage are never accounting authorities.
    module Summary
      module_function

      def unavailable
        {"schema_version" => "m12a-execution-summary-v1", "availability" => "unavailable", "usage" => nil, "cost" => nil}
      end

      def from_attempt(store:, attempt:)
        compact(reconstruct_attempt(store: store, attempt: attempt))
      end

      def compact(summary)
        return summary unless summary["usage"]
        summary.merge("usage" => summary.fetch("usage").except("requests"))
      end

      def reconstruct_attempt(store:, attempt:)
        return unavailable unless attempt["execution"]
        log = attempt["log"]
        raise Error, "execution evidence log missing" unless log.is_a?(Hash) && log["id"]
        persisted = store.artifact(log.fetch("id"))
        raise Error, "execution evidence metadata mismatch" unless persisted == log
        logs = JSON.parse(store.value(persisted))
        record = logs.fetch("execution")
        raise Error, "unsupported execution evidence schema" unless record["schema_version"] == "m12a-execution-v1"
        require_relative "event_stream"
        require_relative "usage"
        process = record.fetch("process", {})
        base = {"schema_version" => "m12a-execution-summary-v1", "availability" => "available",
                "attempt_id" => record["attempt_id"], "evidence" => log.fetch("id"),
                "status" => attempt["status"], "admission" => record["admission"],
                "launch_observed" => record["launch_observed"] == true && process["status"] != "blocked"}
        if !record["launch_observed"] && !record.key?("events") && !process.key?("stdout")
          return base.merge("outcome" => record["outcome"], "usage" => nil, "cost" => nil,
            "completion" => {"operationally_complete" => false, "session_reported_complete" => nil, "accounting_complete" => false})
        end
        stdout = process["stdout"] || logs["stdout"] || record["stdout"]
        unless stdout
          events = record.fetch("events")
          raise Error, "execution events must be an array" unless events.is_a?(Array)
          stdout = events.map { |event| JSON.generate(event.key?("raw") ? event.fetch("raw") : event) }.join("\n")
        end
        parsed = EventStream.parse(stdout: stdout, stderr: process.fetch("stderr", logs.fetch("stderr", "")),
          exit_code: process.fetch("exit_code", logs.fetch("exit_code", record.fetch("exit_code", nil))),
          process_status: process.fetch("status", "unknown"), stdout_truncated: process.fetch("stdout_truncated", false),
          stderr_truncated: process.fetch("stderr_truncated", false), profile: record["model_profile"], identity: record.fetch("identity", {}))
        normalized = Usage.normalize(requests: parsed.fetch("requests"), complete: parsed.dig("completion", "accounting_complete") == true, pricing: record.dig("model_profile", "pricing"))
        base.merge({"schema_version" => "m12a-execution-summary-v1", "availability" => "available",
         "attempt_id" => record["attempt_id"], "evidence" => log.fetch("id"),
         "status" => attempt["status"], "outcome" => parsed["outcome"], "session_id" => parsed["session_id"],
         "completion" => parsed["completion"], "accounting_scope" => parsed["accounting_scope"],
         "protocol_error" => parsed["protocol_error"], "admission" => record["admission"],
         "usage" => normalized.fetch("usage"), "cost" => normalized.fetch("cost")})
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Error, "invalid execution evidence: #{error.message}"
      end

      def from_run(store:, run_id:)
        report = store.report(run_id)
        steps = report.fetch("steps").sort.to_h do |id, step|
          attempts = step.fetch("attempts", []).sort_by { |attempt| attempt.fetch("attempt") }.map do |attempt|
            reconstruct_attempt(store: store, attempt: attempt).merge("attempt" => attempt.fetch("attempt"))
          end
          [id, {"status" => step["status"], "attempts" => attempts}]
        end
        attempts = steps.values.flat_map { |step| step.fetch("attempts") }
        available = attempts.select { |attempt| attempt["availability"] == "available" }
        # Different attempts may reuse native session/message IDs. Keep each
        # attempt's normalized accounting separate; never deduplicate across them.
        accounting = {"usage" => nil, "cost" => nil}
        accounted = available.select { |attempt| attempt["usage"] }
        unless accounted.empty?
          requests = accounted.each_with_index.flat_map do |attempt, index|
            attempt.fetch("usage").fetch("requests").flat_map do |group|
              group.fetch("observations").map do |request|
                request.merge("identity_scope" => "#{run_id}:#{index}:#{request["identity_scope"]}")
              end
            end
          end
          accounting = Usage.normalize(requests: requests, complete: false)
        end
        steps.each_value { |step| step["attempts"] = step.fetch("attempts").map { |attempt| compact(attempt) } }
        compact(unavailable.merge(accounting)).merge("run_id" => run_id, "status" => report["status"], "steps" => steps,
          "availability" => if available.empty?
                              "unavailable"
                            else
                              ((available.size == attempts.size) ? "available" : "partial")
                            end,
          "invocation_count" => available.empty? ? nil : available.count { |attempt| attempt["launch_observed"] == true },
          "attempt_usage" => available.map { |attempt| compact(attempt)["usage"] })
      end
    end
  end
end
