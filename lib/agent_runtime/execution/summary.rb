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
        base.merge!(telemetry(record, []))
        base["process_cleanup"] = cleanup_projection(process["cleanup"])
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
        process_outcome = parsed["outcome"]
        cleanup = record["cleanup"]
        artifact_failed = cleanup.is_a?(Hash) && Array(cleanup["errors"]).any? { |error| error.is_a?(Hash) && error["type"] == "artifact_collection" }
        if artifact_failed
          parsed["outcome"] = "failure"
          parsed["completion"] = parsed.fetch("completion").merge("operationally_complete" => false)
        end
        base.merge!(telemetry(record, parsed["protocol_error"] ? [] : parsed.fetch("events")))
        base.merge({"schema_version" => "m12a-execution-summary-v1", "availability" => "available",
         "attempt_id" => record["attempt_id"], "evidence" => log.fetch("id"),
         "status" => attempt["status"], "outcome" => parsed["outcome"], "session_id" => parsed["session_id"],
         "completion" => parsed["completion"], "accounting_scope" => parsed["accounting_scope"],
          "protocol_error" => parsed["protocol_error"], "admission" => record["admission"],
          "process_outcome" => process_outcome, "artifact_status" => artifact_failed ? "failure" : "unavailable", "cleanup" => cleanup_projection(cleanup),
         "native_cost_observations" => parsed.fetch("native_cost_observations"),
         "cost_evidence" => {"actual_charge_status" => "unknown", "actual_charge" => nil, "estimate" => normalized.dig("usage", "estimate")},
         "usage" => normalized.fetch("usage"), "cost" => normalized.fetch("cost")})
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Error, "invalid execution evidence: #{error.message}"
      end

      # Never expose arbitrary error messages, paths, or extra producer fields.
      def cleanup_projection(cleanup)
        return {"status" => "unknown", "errors" => nil} unless cleanup.is_a?(Hash)
        errors = cleanup["errors"]
        if errors.is_a?(Array)
          projected = errors.map do |error|
            next {"type" => "unknown"} unless error.is_a?(Hash)
            fields = {}
            fields["operation"] = %w[kill reap close].include?(error["operation"]) ? error["operation"] : "unknown" if error.key?("operation")
            fields["type"] = %w[artifact_collection process_cleanup].include?(error["type"]) ? error["type"] : "unknown" if error.key?("type")
            fields["class"] = %w[RuntimeError IOError SystemCallError Errno::ECHILD Errno::ESRCH Errno::EPERM].include?(error["class"]) ? error["class"] : "unknown" if error.key?("class")
            fields.empty? ? {"type" => "unknown"} : fields
          end
        end
        reaped = cleanup["reaped"]
        status = if projected&.any? || reaped == false
          "failure"
        elsif projected == [] && reaped == true
          "success"
        else
          "unknown"
        end
        result = {"status" => status, "errors" => projected}
        result["reaped"] = reaped if [true, false].include?(reaped)
        result
      end

      # Native root steps do not attest upstream routing or complete billing.
      def telemetry(record, events)
        profile = record["model_profile"].is_a?(Hash) ? record["model_profile"] : {}
        policy = profile["tool_policy"].is_a?(Hash) ? profile["tool_policy"] : {}
        requested = %w[provider model].to_h { |field| [field, profile[field]] }
        %w[route endpoint].each { |field| requested[field] = policy.key?(field) ? policy[field] : profile[field] }
        steps = events.select { |event| event["type"] == "step_finish" && event["part"].is_a?(Hash) }
        observed = {"provider" => "providerID", "model" => "modelID", "route" => "route"}.to_h do |field, native|
          values = steps.filter_map do |event|
            value = event.fetch("part")[native]
            value if value.is_a?(String) && !value.empty?
          end.uniq
          [field, values.one? ? values.first : nil]
        end
        preflight = record["preflight"].is_a?(Hash) ? record["preflight"] : {}
        safe_preflight = preflight.slice("status", "allowed", "reason", "deadline", "executable_sha256", "executable_identity", "failure_reason")
          .select { |_, value| value.nil? || value == true || value == false || value.is_a?(String) || (value.is_a?(Numeric) && value.finite?) }
        mismatches = observed.filter_map { |field, value| field if value && requested[field] && value != requested[field] }
        observations = steps.filter_map do |event|
          identity = {"provider" => event.dig("part", "providerID"), "model" => event.dig("part", "modelID"), "route" => event.dig("part", "route")}
            .select { |_, value| value.is_a?(String) && !value.empty? }
          identity unless identity.empty?
        end.uniq
        {"model_identity_evidence" => {
           "requested" => {"status" => (requested.values.any? { |value| !value.nil? }) ? "configured" : "unknown",
                           "source" => "model_profile", "identity" => requested},
           "cli_observed" => {"status" => observations.empty? ? "unknown" : "observed",
                              "source" => "native_root_step", "observations" => observations},
           "gateway_resolved" => {"status" => "unknown", "source" => "unavailable", "identity" => nil},
           "served_attested" => {"status" => "unknown", "source" => "unavailable", "identity" => nil}
         },
         "counts" => {"root_step_observations" => steps.size,
                      "tool_event_observations" => events.count { |event| event["type"] == "tool_use" }},
         "identity" => {"requested" => requested,
                        "observed" => observed, "observation_basis" => "native_root_step", "verification" => "unknown",
                        "discrepancy" => mismatches.empty? ? "unknown" : "observed_requested_mismatch", "mismatched_fields" => mismatches},
         "preflight" => safe_preflight,
         "accounting_coverage" => {"complete" => false, "root_steps" => steps.empty? ? "unknown" : "partial",
                                   "usage_scope" => "solver_only", "grader_overhead" => "unknown",
                                   "grader_overhead_source" => "unavailable_in_execution_evidence",
                                   "provider_requests" => "unknown", "provider_retries" => "unknown",
                                   "auxiliary_usage" => "unknown", "title_usage" => "unknown", "compaction_usage" => "unknown", "child_usage" => "unknown",
                                   "provider_charges" => "unknown", "reported_cost_basis" => "native_step_observations", "billing_status" => "not_provider_billing"}}
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
