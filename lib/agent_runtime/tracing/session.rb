require_relative "store"

module AgentRuntime
  module Tracing
    # Host-owned instrumentation. This object is never serialized into solver config.
    class Session
      attr_reader :trace, :artifacts, :raw_content

      def initialize(trace:, artifacts:, raw_content: false)
        @trace, @artifacts, @raw_content = trace, artifacts, raw_content
      end

      def context
        Thread.current[:agru_trace_context] || {}
      end

      def within(parent_id, attributes = {})
        previous = Thread.current[:agru_trace_context]
        Thread.current[:agru_trace_context] = {parent_id: parent_id, attributes: attributes}
        yield
      ensure
        Thread.current[:agru_trace_context] = previous
      end

      def start(kind, parent: nil, attributes: {})
        trace.start(kind: kind, parent_id: parent || context[:parent_id],
          attributes: context.fetch(:attributes, {}).merge(attributes),
          provenance: {"source" => "agru_host_instrumentation", "runtime_version" => AgentRuntime::VERSION})
      end

      def finish(id, status, attributes = {})
        trace.finish(id, status: status, attributes: attributes)
      end

      def event(kind, parent:, attributes: {})
        id = start(kind, parent: parent, attributes: attributes)
        finish(id, "success")
        id
      end

      def reference(artifact)
        artifacts.value(artifacts.artifact(artifact.fetch("id")))
        artifact.slice("id", "digest", "type", "run_id", "step_id", "attempt", "inputs", "metadata")
      end

      def handoff(parent:, inputs:, contract:, direction:, outputs: nil, validation: nil)
        refs = inputs.transform_values { |artifact| reference(artifact) }
        attributes = {"direction" => direction, "contract" => contract, "artifacts" => refs,
                      "expected_inputs" => contract.keys, "actual_inputs" => refs.keys,
                      "missing_inputs" => contract.keys - refs.keys, "validation" => validation,
                      "outputs" => outputs, "content_availability" => raw_content ? "authorized" : "raw_capture_not_authorized"}
        if raw_content
          attributes["values"] = trace.payload(inputs.to_h { |name, artifact|
            value = artifacts.value(artifact)
            [name, %w[repository directory file].include?(artifact["type"]) ? reference(artifact) : value]
          }, raw: true)
        end
        event("handoff", parent: parent, attributes: attributes)
      end

      def checkpoint(parent:, repository:, run_id:, stage:, attempt:, boundary:)
        require_relative "../benchmarks/submission"
        artifact = Benchmarks::Submission.new(store: artifacts).capture(repository: repository,
          run_id: run_id, step_id: stage, attempt: attempt, preserve_modes: true)
        manifest = AgentRuntime::Store.manifest(artifacts.value(artifact))
        sidecar = artifacts.value(artifacts.artifact(artifact.dig("metadata", "mode_evidence", "id")))
        modes = sidecar.fetch("entries").to_h { |entry| [entry.fetch("path"), entry.fetch("mode")] }
        files = manifest.to_h { |entry| [entry.fetch("path"), {"digest" => Digest::SHA256.hexdigest(entry.fetch("content").unpack1("m0")), "mode" => modes.fetch(entry.fetch("path")), "bytes" => entry.fetch("content").unpack1("m0").bytesize}] }
        attrs = {"boundary" => boundary, "run_id" => run_id, "stage" => stage, "attempt" => attempt,
                 "artifact" => reference(artifact), "files" => files, "modes" => modes, "snapshot_available" => raw_content,
                 "content_availability" => raw_content ? "authorized" : "raw_capture_not_authorized"}
        attrs["snapshot"] = trace.payload({"manifest" => manifest, "modes" => sidecar}, raw: true) if raw_content
        event("checkpoint", parent: parent, attributes: attrs)
      end

      def execution(parent:, logs:, error: nil)
        return event("capture_gap", parent: parent, attributes: {"reason" => "execution_log_unavailable", "error" => error}) unless logs.is_a?(Hash)
        execution = logs.fetch("execution", {})
        events = execution.fetch("events", [])
        # Native messageID is not a provider request ID: preserve that distinction.
        events.each_with_index do |native, sequence|
          next unless native["type"] == "tool_use"
          part = native.fetch("part", {})
          state = part.fetch("state", {})
          attrs = {"tool" => part["tool"], "native_id" => part["id"], "native_message_id" => part["messageID"],
                   "native_sequence" => sequence, "observed_timestamp" => native["timestamp"],
                   "tool_status" => state["status"], "provider_request_id" => nil,
                   "association" => "native_message_only", "working_directory" => nil,
                   "exit_status" => state.dig("metadata", "exit"), "observed_time" => state["time"],
                   "failure_classification" => (state["status"] == "error") ? "tool_error" : nil,
                   "content_availability" => raw_content ? "authorized" : "raw_capture_not_authorized"}
          attrs["payload"] = trace.payload(part, raw: true) if raw_content
          id = start("tool", parent: parent, attributes: attrs)
          finish(id, if state["status"] == "error"
            "failure"
          else
            (state["status"] == "completed") ? "success" : "incomplete"
          end)
        end
        event("execution_evidence", parent: parent, attributes: {"native_events" => events.size,
                                                                 "native_tool_events" => events.count { |e| e["type"] == "tool_use" },
                                                                 "completion" => execution["completion"], "protocol_error" => execution["protocol_error"],
                                                                 "coverage" => "OpenCode native events; not all shell side effects", "error" => error})
      end

      def provider_records(parent:, records:)
        records.each do |envelope|
          payload = envelope.fetch("payload")
          serialized = envelope.fetch("payload_json")
          raise Error, "provider capture digest mismatch" unless Digest::SHA256.hexdigest(serialized) == envelope.fetch("digest") && JSON.parse(serialized) == payload
          attrs = payload.except("request_body", "response_chunks", "events", "reconstructed_response")
          attrs["capture_digest"] = envelope.fetch("digest")
          attrs["response_complete"] = payload["complete"] == true
          attrs["request"] = payload["request_id"]
          attrs["usage_correlated"] = !payload["usage"].nil?
          attrs["usage_request_id"] = payload["request_id"]
          attrs["payload"] = trace.payload(payload, raw: true) if raw_content
          attrs["content_availability"] = raw_content ? "authorized" : "raw_capture_not_authorized"
          id = start("llm_request", parent: parent, attributes: attrs)
          finish(id, if payload["error"]
            "failure"
          else
            (payload["complete"] == false) ? "incomplete" : "success"
          end)
        end
      end
    end
  end
end
