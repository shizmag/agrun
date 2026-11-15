require "json"

module AgentRuntime
  module Execution
    # Version-specific CLI observations, not a provider request or billing log.
    # Raw events/tool states may contain secrets; callers control persistence.
    module EventStream
      class << self
        def parse(stdout:, stderr: "", stdout_truncated: false, stderr_truncated: false,
          exit_code: 0, process_status: "success", profile: nil, identity: {})
          record = {"schema_version" => "m12a-execution-v1", "events" => [],
                    "requests" => [], "session_id" => nil, "protocol_error" => nil,
                    "outcome" => "unknown", "completion" => {"operationally_complete" => false,
                                                             "session_reported_complete" => nil, "accounting_complete" => false},
                    "tool_calls" => [], "identity" => identity.dup,
                    "native_cost_observations" => [], "accounting_scope" => "root_steps"}
          error(record, "stdout_truncated", "Protocol output was truncated") if stdout_truncated
          stdout.each_line.with_index(1) do |line, number|
            next if line.strip.empty?
            begin
              event = JSON.parse(line)
            rescue JSON::ParserError, EncodingError
              error(record, "invalid_json", "Protocol record is not valid JSON", number)
              next
            end
            unless event.is_a?(Hash)
              error(record, "nonobject_record", "Protocol record must be an object", number)
              next
            end
            record["events"] << event
            consume(record, event, identity, number)
          end
          requested = identity["requested_session_id"]
          if requested && record["session_id"] && requested != record["session_id"]
            error(record, "session_mismatch", "Requested and observed sessions differ")
          end
          terminal_error = record["events"].any? { |event| event["type"] == "error" }
          record["outcome"] = if %w[timeout cancelled].include?(process_status)
            process_status
          elsif terminal_error || (exit_code.is_a?(Integer) && exit_code != 0) || process_status == "failure"
            "failure"
          elsif record["protocol_error"] || process_status != "success" || exit_code != 0 || record["requests"].empty?
            "unknown"
          else
            "success"
          end
          record["completion"]["operationally_complete"] = record["outcome"] == "success"
          record
        end

        private

        def error(record, code, message, line = nil)
          record["protocol_error"] ||= {"type" => "protocol", "code" => code, "message" => message, "line" => line}
        end

        def nonempty?(value)
          value.is_a?(String) && !value.empty?
        end

        def consume(record, event, identity, line)
          unless nonempty?(event["type"])
            error(record, "missing_event_type", "Protocol event type is missing", line)
            return
          end
          session = event["sessionID"]
          # Setup errors can precede session creation.
          setup_error = event["type"] == "error" && (session.nil? || session == "")
          unless setup_error
            unless nonempty?(session)
              error(record, "missing_session", "Protocol session identity is missing", line)
              return
            end
            if record["session_id"] && record["session_id"] != session
              error(record, "mixed_sessions", "Protocol contains multiple sessions", line)
              return
            end
            record["session_id"] ||= session
          end
          return unless %w[step_start step_finish text reasoning tool_use].include?(event["type"])
          part = event["part"]
          expected = {"step_start" => "step-start", "step_finish" => "step-finish", "tool_use" => "tool"}.fetch(event["type"], event["type"])
          unless part.is_a?(Hash) && nonempty?(part["id"]) && nonempty?(part["messageID"]) && part["sessionID"] == session && part["type"] == expected
            error(record, "invalid_part_identity", "Protocol part identity or type is invalid", line)
            return
          end
          if event["type"] == "tool_use"
            record["tool_calls"] << part
          elsif event["type"] == "step_finish"
            finish(record, part, identity)
          end
        end

        def finish(record, part, identity)
          tokens = part["tokens"].is_a?(Hash) ? part["tokens"] : {}
          cache = tokens["cache"].is_a?(Hash) ? tokens["cache"] : {}
          observation_id = JSON.generate([part["sessionID"], part["messageID"]])
          scope = identity["invocation_id"]
          unless nonempty?(scope)
            scope = if identity.key?("run_id")
              JSON.generate(identity.values_at("run_id", "step_id", "attempt"))
            else
              "invocation_local"
            end
          end
          record["requests"] << {"request_id" => observation_id,
                                 "identity_kind" => "root_step_observation", "identity_scope" => scope,
                                 "provider" => nil, "model" => nil,
                                 "tokens" => {"input" => tokens["input"], "output" => tokens["output"],
                                              "reasoning" => tokens["reasoning"], "cache_read" => cache["read"], "cache_write" => cache["write"]},
                                 "input_cache_relation" => "disjoint", "output_reasoning_relation" => "disjoint", "reported_cost" => nil}
          if part.key?("cost")
            record["native_cost_observations"] << {"request_id" => observation_id, "identity_scope" => scope,
                                                   "identity_kind" => "root_step_observation", "value" => part["cost"], "provenance" => "opaque_cli"}
          end
        end
      end
    end
  end
end
