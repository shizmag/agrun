require "json"
require_relative "process_runner"
require_relative "git_patch"

module AgentRuntime
  module Adapters
    class OpenCodeCLI
      def initialize(runner: ProcessRunner.new, executable: "opencode", live: false)
        @runner, @executable, @live = runner, executable, live
      end

      def execute(request)
        config = request.config || {}
        unless @live || config["live"] == true
          return Result.new(status: "blocked", outputs: {}, error: {"type" => "live_opt_in_required", "message" => "OpenCode requires explicit live: true"}, logs: {})
        end
        prompt = config.fetch("prompt") { request.inputs.fetch("prompt") }
        raise ArgumentError, "prompt must be a nonempty string" unless prompt.is_a?(String) && !prompt.empty?
        argv = [@executable, "run", "--format", "json", "--standalone"]
        {"model" => "--model", "agent" => "--agent", "session_id" => "--session"}.each do |key, flag|
          argv.concat([flag, config[key]]) if config[key]
        end
        argv.concat(["--", prompt])
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        execution, patch = GitPatch.new(directory).capture do
          @runner.call(argv: argv, cwd: directory, timeout: request.timeout,
            cancellation: request.cancellation, env: config.fetch("env", {}))
        end
        result = translate(execution, request, config)
        result.outputs["patch"] = patch
        result
      rescue ArgumentError, KeyError => error
        Result.new(status: "failure", outputs: {}, error: {"type" => "configuration", "message" => error.message}, logs: {})
      end

      private

      def translate(execution, request, config)
        events = execution["stdout"].lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
        raise JSON::ParserError, "events must be JSON objects" unless events.all? { |event| event.is_a?(Hash) }
        text = events.select { |event| event["type"] == "text" }.map { |event| event.dig("part", "text").to_s }.join
        finishes = events.select { |event| event["type"] == "step_finish" }
        error_event = events.find { |event| event["type"] == "error" }
        status = execution["status"]
        status = "failure" if status == "success" && error_event
        status = "blocked" if error_event && JSON.generate(error_event).match?(/permission|approval|denied/i)
        status = "unknown" if status == "success" && finishes.empty?
        session_id = events.rfind { |event| event["sessionID"] }&.fetch("sessionID")
        usage = finishes.filter_map { |event| event.dig("part", "tokens") }
        costs = finishes.filter_map { |event| event.dig("part", "cost") }
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        observed_model = events.filter_map { |event| event.dig("part", "modelID") || event["modelID"] }.last
        Result.new(status: status, outputs: {"text" => text, "repository" => directory, "requested_model" => config["model"]},
          error: (status == "success") ? nil : (error_event || {"type" => status, "message" => "OpenCode #{status}"}),
          duration: execution["duration"], logs: execution.slice("stdout", "stderr"),
          session_id: session_id, model: observed_model, usage: usage.empty? ? nil : {"steps" => usage},
          cost: costs.empty? ? nil : costs.sum)
      rescue JSON::ParserError, TypeError, NoMethodError => error
        Result.new(status: (execution["status"] == "success") ? "unknown" : execution["status"],
          outputs: {}, error: {"type" => "invalid_output", "message" => "invalid OpenCode JSON events: #{error.message}"},
          duration: execution["duration"], logs: execution.slice("stdout", "stderr"))
      end
    end
  end
end
