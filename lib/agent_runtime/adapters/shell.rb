require_relative "process_runner"

module AgentRuntime
  module Adapters
    class Shell
      def initialize(runner: ProcessRunner.new)
        @runner = runner
      end

      def execute(request)
        config = request.config || {}
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        execution = @runner.call(argv: config.fetch("argv"), cwd: directory,
          timeout: request.timeout, cancellation: request.cancellation, env: config.fetch("env", {}))
        Result.new(status: execution["status"], outputs: execution.slice("stdout", "stderr", "exit_code"),
          duration: execution["duration"], logs: execution.slice("stdout", "stderr"),
          error: (execution["status"] == "success") ? nil : {"type" => execution["status"], "message" => "process #{execution["status"]} (exit #{execution["exit_code"].inspect})"})
      rescue ArgumentError, KeyError => error
        Result.new(status: "failure", outputs: {}, error: {"type" => "configuration", "message" => error.message}, logs: {})
      end
    end
  end
end
