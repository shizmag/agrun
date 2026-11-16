module AgentRuntime
  module Benchmarks
    class ResourceReport
      FIELDS = %w[requests input cache_read cache_write output reasoning wall_seconds tool_events retries provider_errors].freeze

      def summary(cells:, evidence_kind:)
        rows = cells.map do |cell|
          usage = cell["usage"] || {}
          coverage = usage["coverage"] || {}
          metrics = %w[input cache_read cache_write output reasoning].to_h do |field|
            token = usage.dig("tokens", field) || {}
            [field, measure(token["total"], token["known_subtotal"])]
          end
          complete = coverage["stream_complete"] == true && coverage["identity_kind"] == "provider_request" && coverage["conflicting_requests"] == 0 && coverage["unidentified_observations"] == 0
          metrics["requests"] = measure(complete ? coverage["accepted_requests"] : nil, coverage["accepted_requests"])
          metrics["wall_seconds"] = measure(cell["agent_duration"])
          metrics["tool_events"] = measure(nil, cell.dig("execution", "counts", "tool_event_observations"))
          metrics["retries"] = measure(nil)
          metrics["provider_errors"] = measure(nil)
          {"id" => cell["id"], "architecture" => cell["solver_id"], "model" => cell["model"], "metrics" => metrics}
        end
        arms = rows.group_by { |row| row.values_at("architecture", "model") }.map do |(architecture, model), group|
          metrics = FIELDS.to_h do |field|
            values = group.map { |row| row.fetch("metrics").fetch(field) }
            known = values.filter_map { |value| value["known_subtotal"] }
            total = (values.all? { |value| value["complete"] }) ? known.sum : nil
            [field, measure(total, known.empty? ? nil : known.sum).merge("known" => known.size, "expected" => values.size)]
          end
          {"architecture" => architecture, "model" => model, "metrics" => metrics}
        end
        {"evidence_kind" => evidence_kind, "synthetic" => evidence_kind != "live_provider", "cells" => rows, "architectures" => arms}
      end

      def render(cells:, evidence_kind:)
        data = summary(cells: cells, evidence_kind: evidence_kind)
        lines = ["## Resource observations", "", "Evidence: #{evidence_kind}; synthetic: #{data.fetch("synthetic")}. Totals require completeness; subtotals retain partial known evidence. Unknown is never zero. Cache/reasoning may overlap input/output and are not added. Tool events are observed events, not complete tool-call counts. Saved summaries do not expose authoritative retry/provider-error counts.", ""]
        {"Per-cell resources" => data["cells"], "Per-architecture resources (separate model routes)" => data["architectures"]}.each do |title, rows|
          lines.concat(["### #{title}", "", "| Cell / architecture | Model | #{FIELDS.join(" | ")} |", "|---|---|#{FIELDS.map { "---:" }.join("|")}|"])
          rows.each do |row|
            values = FIELDS.map do |field|
              value = row.fetch("metrics").fetch(field)
              number = value["total"] || value["known_subtotal"]
              if number.nil?
                "unknown"
              else
                "#{number}#{" subtotal" unless value["complete"]} (#{value["known"]}/#{value["expected"]} known)"
              end
            end
            lines << "| #{safe(row["id"] || row["architecture"])} | #{safe(row["model"])} | #{values.join(" | ")} |"
          end
          lines << ""
        end
        lines.join("\n")
      end

      private

      def measure(total, subtotal = nil)
        total = nil unless total.is_a?(Numeric) && total.finite? && total >= 0
        subtotal = total unless total.nil?
        subtotal = nil unless subtotal.is_a?(Numeric) && subtotal.finite? && subtotal >= 0
        {"total" => total, "known_subtotal" => subtotal, "complete" => !total.nil?, "known" => subtotal.nil? ? 0 : 1, "expected" => 1}
      end

      def safe(value)
        value.nil? ? "unknown" : value.to_s.gsub(/[|\r\n]/, " ")
      end
    end
  end
end
