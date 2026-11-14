require "json"

module AgentRuntime
  module Benchmarks
    class Reports
      COLUMNS = %w[id task_id solver_id model repetition status execution_status score verdict protocol quality_basis trust_scope reason failure_category expected collected executed passed failed skipped total usage cost error attempt_id submission grading_attempts agent_duration grading_duration].freeze

      def initialize(store:)
        @store = store
      end

      def summary(experiment_id:)
        report = @store.report(experiment_id)
        cells = report.fetch("cells")
        repetitions = report.fetch("manifest").fetch("repetitions")
        arms = cells.group_by { |cell| [cell.fetch("solver_id"), cell["model"], cell["protocol"], cell["quality_basis"]] }.map do |(solver, model, protocol, quality_basis), rows|
          tasks = rows.group_by { |row| row.fetch("task_id") }
          included, excluded = tasks.partition do |_, task_rows|
            task_rows.size == repetitions && task_rows.map { |row| row["repetition"] }.uniq.size == repetitions && task_rows.all? { |row| valid?(row) }
          end.map(&:to_h)
          means = included.values.map { |task_rows| mean(task_rows.map { |row| row.fetch("score") }) }
          costs = rows.filter_map { |row| row["cost"] if row["cost"].is_a?(Numeric) }
          counts = rows.select { |row| valid?(row) && row["passed"].is_a?(Numeric) && row["total"].is_a?(Numeric) }
          {"solver_id" => solver, "model" => model, "protocol" => protocol, "quality_basis" => quality_basis, "macro_score" => mean(means),
           "full_solve_fraction" => mean(included.values.map { |task_rows| (task_rows.all? { |row| row["score"] == 1 }) ? 1.0 : 0.0 }),
           "included_tasks" => included.keys, "excluded_tasks" => excluded.keys,
           "exclusion_reasons" => excluded.transform_values { |task_rows| task_rows.map { |row| {"repetition" => row["repetition"], "execution_status" => row["execution_status"], "error" => row["error"]} } },
           "conditional_denominator" => included.size, "total_tasks" => tasks.size,
           "valid_cells" => rows.count { |row| valid?(row) }, "invalid_cells" => rows.count { |row| !valid?(row) },
           "status_counts" => rows.group_by { |row| row["execution_status"] || row["status"] }.transform_values(&:size),
           "pooled_counts" => {"passed" => counts.empty? ? nil : counts.sum { |row| row["passed"] }, "total" => counts.empty? ? nil : counts.sum { |row| row["total"] }, "coverage" => counts.size},
           "count_evidence" => %w[expected collected executed passed failed skipped].to_h do |key|
             known = rows.select { |row| valid?(row) && row[key].is_a?(Integer) && row[key] >= 0 }
             [key, {"total" => known.empty? ? nil : known.sum { |row| row[key] }, "known_cells" => known.size}]
           end,
           "protocol_known_cells" => rows.count { |row| row["protocol"].is_a?(String) && !row["protocol"].empty? },
           "quality_basis_known_cells" => rows.count { |row| row["quality_basis"].is_a?(String) && !row["quality_basis"].empty? },
           "evidence_coverage" => evidence_coverage(rows),
           "cost_total" => costs.empty? ? nil : costs.sum, "cost_known_cells" => costs.size,
           "usage_known_cells" => rows.count { |row| !row["usage"].nil? }}
        end
        statuses = cells.group_by { |row| row["execution_status"] || row["status"] }.transform_values(&:size)
        completed = cells.count { |row| valid?(row) }
        timings = {"agent" => timing(cells, "agent_duration"), "grading" => timing(cells, "grading_duration")}
        combined = cells.map do |row|
          durations = row.values_at("agent_duration", "grading_duration")
          {"recorded_total" => (durations.all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 }) ? durations.sum : nil}
        end
        timings["agent_plus_grading"] = timing(combined, "recorded_total")
        {"experiment_id" => experiment_id, "manifest" => report["manifest"], "manifest_digest" => report["manifest_digest"],
         "qualification" => report.fetch("qualification", "infrastructure-only demonstration"),
         "provenance" => report["provenance"], "effective_parallelism" => report["effective_parallelism"],
         "arms" => arms, "paired" => paired(cells), "per_task_results" => cells.group_by { |row| row.fetch("task_id") },
         "execution_counts" => {"planned" => cells.size, "completed" => cells.count { |row| row["status"] == "completed" || valid?(row) },
                                "failed" => statuses.fetch("error", 0) + statuses.fetch("timeout", 0), "cancelled" => statuses.fetch("cancelled", 0),
                                "missing" => statuses.fetch("not_started", 0), "unavailable" => statuses.fetch("unavailable", 0), "by_status" => statuses},
         "evaluation_completion" => {"completed" => completed, "planned" => cells.size, "fraction" => cells.empty? ? nil : completed.fdiv(cells.size)},
         "evidence_coverage" => evidence_coverage(cells),
         "timings" => timings,
         "limitations" => [((cells.any? { |cell| cell["protocol"] == "nl2repo-audited-v2" }) ?
            "Audited-v2 evidence covers controlled ordinary submissions only, not malicious-submission authentication or scientific capability evidence." :
            "Infrastructure-only fixture results; not scientific capability evidence."),
           "Timing totals and percentiles cover recorded cells only; missing timings remain unknown.",
           "Tool usage is unavailable unless explicitly recorded.",
           "Usage and costs with missing coverage are unknown, not zero."],
         "interpretation" => if cells.any? { |cell| cell["protocol"] == "nl2repo-audited-v2" }
                               "Audited-v2 quality is scoped to controlled ordinary submissions; not authenticated against malicious Python. Other protocols and missing quality evidence are separate; no official score or scientific capability claim."
                             else
                               (report["qualification"] == "provisional official-benchmark integration") ?
                                           "Provisional NL2Repo integration; untrusted diagnostics are not official scores or scientific capability evidence." :
                                           "Offline fixture plumbing check; not scientific capability evidence."
                             end}
      end

      def render(experiment_id:, format: "json")
        report = @store.report(experiment_id)
        aggregate = summary(experiment_id: experiment_id)
        case format.to_s
        when "json"
          JSON.pretty_generate(report.merge("summary" => aggregate))
        when "csv"
          rows = [COLUMNS] + report.fetch("cells").map do |cell|
            COLUMNS.map { |key| (cell[key].is_a?(Hash) || cell[key].is_a?(Array)) ? JSON.generate(cell[key]) : cell[key] }
          end
          rows.map { |row| row.map { |value| '"' + value.to_s.gsub('"', '""') + '"' }.join(",") }.join("\r\n") + "\r\n"
        when "markdown"
          lines = ["# Experiment #{escape(experiment_id)}", "", aggregate.fetch("interpretation"), "", "| Solver | Model | Protocol | Quality basis | Macro score | Included tasks | Excluded tasks | Valid / invalid | Count coverage |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
          aggregate.fetch("arms").each do |arm|
            lines << "| #{escape(arm["solver_id"])} | #{escape(arm["model"])} | #{escape(arm["protocol"] || "null")} | #{escape(arm["quality_basis"] || "null")} | #{arm["macro_score"] || "null"} | #{escape(arm["included_tasks"].join(", "))} | #{escape(arm["excluded_tasks"].join(", "))} | #{arm["valid_cells"]} / #{arm["invalid_cells"]} | #{escape(JSON.generate(arm["count_evidence"]))} |"
          end
          lines.concat(["", "## Identity and execution", "", "Manifest digest: #{escape(aggregate["manifest_digest"] || "unknown")}",
            "Provenance: #{escape(JSON.generate(aggregate["provenance"]))}",
            "Execution counts: #{escape(JSON.generate(aggregate["execution_counts"]))}",
            "Evaluation completion: #{escape(JSON.generate(aggregate["evaluation_completion"]))}",
            "Evidence coverage: #{escape(JSON.generate(aggregate["evidence_coverage"]))}",
            "Timings (recorded coverage only): #{escape(JSON.generate(aggregate["timings"]))}", "", "## Limitations", ""])
          aggregate.fetch("limitations").each { |limitation| lines << "- #{limitation}" }
          lines.concat(["", "## Raw cells", "", "| #{COLUMNS.join(" | ")} |", "| #{COLUMNS.map { "---" }.join(" | ")} |"])
          report.fetch("cells").each { |cell| lines << "| #{COLUMNS.map { |key| escape(cell[key].nil? ? "null" : cell[key]) }.join(" | ")} |" }
          lines.join("\n") + "\n"
        else
          raise ArgumentError, "unknown report format #{format}"
        end
      end

      private

      def evidence_coverage(cells)
        dimensions = %w[execution_status quality_basis reason failure_category protocol trust_scope].to_h do |key|
          values = cells.filter_map { |row| row[key] unless row[key].nil? || row[key] == "" }
          ["by_#{key}", values.tally]
        end
        dimensions.merge("planned_cells" => cells.size, "valid_score_cells" => cells.count { |row| valid?(row) },
          "missing_score_cells" => cells.count { |row| row["score"].nil? },
          "protocol_known_cells" => cells.count { |row| row["protocol"].is_a?(String) && !row["protocol"].empty? },
          "quality_basis_known_cells" => cells.count { |row| row["quality_basis"].is_a?(String) && !row["quality_basis"].empty? })
      end

      def timing(cells, key)
        values = cells.filter_map do |row|
          value = row[key]
          value if value.is_a?(Numeric) && value.finite? && value >= 0
        end.sort
        {"total" => values.empty? ? nil : values.sum, "p50" => percentile(values, 0.5), "p95" => percentile(values, 0.95),
         "known_cells" => values.size, "planned_cells" => cells.size}
      end

      def percentile(values, quantile)
        values.empty? ? nil : values[[(values.size * quantile).ceil - 1, 0].max]
      end

      def valid?(row)
        score = row["score"]
        row["execution_status"] == "success" && score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
      end

      def mean(values)
        values.empty? ? nil : values.sum.fdiv(values.size)
      end

      def paired(cells)
        cells.group_by { |row| [row["solver_id"], row["model"], row["protocol"], row["quality_basis"]] }.to_a.combination(2).filter_map do |(left, left_rows), (right, right_rows)|
          next unless left[2..] == right[2..]
          a = left_rows.to_h { |row| [[row["task_id"], row["repetition"]], row] }
          b = right_rows.to_h { |row| [[row["task_id"], row["repetition"]], row] }
          coordinates = a.keys | b.keys
          eligible = coordinates.select { |key| a[key] && b[key] && valid?(a[key]) && valid?(b[key]) }
          {"left" => left.first(2), "right" => right.first(2), "protocol" => left[2], "quality_basis" => left[3], "included_coordinates" => eligible, "excluded_coordinates" => coordinates - eligible,
           "conditional_denominator" => eligible.size, "scientific_delta" => nil,
           "fixture_diagnostic_delta" => mean(eligible.map { |key| a[key]["score"] - b[key]["score"] })}
        end
      end

      def escape(value)
        value.to_s.gsub("|", "\\|").tr("\n", " ")
      end
    end
  end
end
