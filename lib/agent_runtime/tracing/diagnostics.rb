require "digest"

module AgentRuntime
  module Tracing
    # Deterministic evidence summaries. Correlation is never reported as causation.
    class Diagnostics
      def initialize(entities)
        @entities = entities
      end

      def analyze
        requests = select_kind("request")
        tools = select_kind("tool")
        checkpoints = select_kind("checkpoint")
        observations = {
          "entities" => @entities.length,
          "requests" => requests.length,
          "tools" => tools.length,
          "handoffs" => select_kind("handoff").length,
          "latency_unit" => "seconds",
          "retries" => @entities.count { |entity| attributes(entity)["retry_of"] || attributes(entity)["retry"] == true || ((entity["kind"] == "attempt") && attributes(entity)["attempt"].to_i > 1) },
          "tokens" => numeric_total(requests, "tokens"),
          "latency" => numeric_total(requests, "latency"),
          "token_buckets" => token_buckets(requests),
          "tool_statuses" => tools.group_by { |entity| entity["status"] || "unknown" }.transform_values(&:length),
          "statuses" => @entities.group_by { |entity| entity["status"] || attributes(entity)["status"] || "unknown" }.transform_values(&:length),
          "checkpoint_diffs" => checkpoint_groups(checkpoints).flat_map { |group| group.each_cons(2).map { |left, right| diff(left, right) } },
          "overwrites_and_reverts" => checkpoint_groups(checkpoints).flat_map { |group| changes(group) },
          "handoff_contracts" => select_kind("handoff").map { |entity| {"id" => entity["id"], "contract" => attributes(entity)["contract"], "status" => attributes(entity)["contract_status"] || attributes(entity)["validation"] || "unknown"} }
        }
        {"observations" => observations, "hypotheses" => [], "limitations" => ["Missing telemetry remains unknown; observations do not establish causation or complete provider accounting."]}
      end

      def diff(left, right)
        before = files(left)
        after = files(right)
        common = before.keys & after.keys
        {"from" => left["id"], "to" => right["id"],
         "added" => (after.keys - before.keys).sort,
         "deleted" => (before.keys - after.keys).sort,
         "modified" => common.select { |path| before[path] != after[path] }.sort,
         "mode_changes" => mode_changes(left, right),
         "complete" => manifest_present?(left) && manifest_present?(right)}
      end

      private

      def checkpoint_groups(checkpoints)
        checkpoints.group_by do |entity|
          attrs = attributes(entity)
          [attrs["experiment_id"], attrs["cell_id"], attrs["run_id"] || entity["parent_id"]]
        end.values
      end

      def mode_changes(left, right)
        before = attributes(left)["modes"] || {}
        after = attributes(right)["modes"] || {}
        (before.keys | after.keys).select { |path| before[path] != after[path] }.sort
      end

      def changes(checkpoints)
        history = Hash.new { |hash, path| hash[path] = [] }
        observations = []
        checkpoints.each do |checkpoint|
          files(checkpoint).sort.each do |path, identity|
            previous = history[path]
            if !previous.empty? && previous.last != identity
              observations << {"checkpoint" => checkpoint["id"], "path" => path,
                               "observation" => previous.include?(identity) ? "revert" : "overwrite"}
            end
            previous << identity
          end
        end
        observations
      end

      def attributes(entity)
        value = entity["attributes"] || entity["attrs"] || {}
        value.is_a?(Hash) ? value : {}
      end

      def select_kind(kind)
        @entities.select { |entity| ((kind == "request") ? %w[request llm_request] : [kind]).include?((entity["kind"] || entity["type"]).to_s) }
      end

      def numeric_total(entities, key)
        values = entities.map do |entity|
          attrs = attributes(entity)
          if key == "latency"
            attrs["latency"] || attrs["duration"] || (attrs["duration_ms"].is_a?(Numeric) && attrs["duration_ms"] / 1000.0) || (entity["kind"] == "request" && entity["duration"])
          elsif key == "tokens"
            if attrs["tokens"].is_a?(Numeric)
              attrs["tokens"]
            else
              (attrs["usage"].is_a?(Hash) ? attrs["usage"]["total_tokens"] : nil)
            end
          else
            attrs[key]
          end
        end
        {"observed" => values.grep(Numeric).sum, "known" => values.count { |value| value.is_a?(Numeric) }, "unknown" => values.count { |value| !value.is_a?(Numeric) }}
      end

      def flatten_usage(usage, prefix = "")
        usage.each_with_object({}) do |(key, value), result|
          name = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          if value.is_a?(Hash)
            result.merge!(flatten_usage(value, name))
          else
            result[name] = value
          end
        end
      end

      def token_buckets(requests)
        keys = requests.flat_map do |entity|
          usage = attributes(entity)["usage"]
          usage.is_a?(Hash) ? flatten_usage(usage).keys.grep(/token/) : []
        end.uniq.sort
        keys.to_h do |key|
          values = requests.map { |entity| attributes(entity).fetch("usage", {}) }.map { |usage| usage.is_a?(Hash) ? flatten_usage(usage)[key] : nil }
          [key, {"observed" => values.grep(Numeric).sum, "known" => values.grep(Numeric).length, "unknown" => values.count { |value| !value.is_a?(Numeric) }}]
        end
      end

      def manifest_present?(entity)
        attrs = attributes(entity)
        attrs["files"].is_a?(Hash) || attrs["manifest"].is_a?(Array)
      end

      def files(entity)
        attrs = attributes(entity)
        return attrs["files"] if attrs["files"].is_a?(Hash)
        Array(attrs["manifest"]).to_h do |entry|
          content = entry["content"]
          digest = entry["digest"] || (content && Digest::SHA256.hexdigest(content.unpack1("m0")))
          [entry.fetch("path"), {"digest" => digest, "executable" => entry["executable"], "mode" => entry["mode"]}]
        end
      end
    end
  end
end
