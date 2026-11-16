require_relative "../execution/sandbox_open_code_launch"
require_relative "../execution/event_stream"
require_relative "../execution/usage"

module AgentRuntime
  module Adapters
    # Additive mock integration; never delegates to the historical host adapter.
    class SandboxOpenCodeCLI
      def initialize(runner:, launch:)
        raise ArgumentError, "sandbox launch required" unless launch.instance_of?(Execution::SandboxOpenCodeLaunch)
        @runner, @launch = runner, launch
      end

      def execute(request)
        directory = request.inputs&.fetch("repository", nil) || request.workspace
        prompt = (request.config || {}).fetch("prompt") { request.inputs.fetch("prompt") }
        execution = @runner.call(argv: @launch.argv(prompt), workspace: directory,
          timeout: request.timeout, cancellation: request.cancellation, env: @launch.environment)
        evidence = execution.slice("container_inspect", "cleanup", "export", "image_digest", "resource_policy", "container_name")
        exported = execution.dig("export", "path")
        verified = execution["container_inspect"].is_a?(Hash) && execution.dig("cleanup", "confirmed") == true &&
          exported.is_a?(String) && File.directory?(exported) && execution.dig("export", "digest").is_a?(String)
        status = execution.fetch("status")
        status = "blocked" if status == "success" && !verified
        observations = Execution::EventStream.parse(stdout: execution.fetch("stdout", ""), stderr: execution.fetch("stderr", ""),
          stdout_truncated: execution.fetch("stdout_truncated", false), stderr_truncated: execution.fetch("stderr_truncated", false),
          exit_code: execution["exit_code"], process_status: status, identity: @launch.to_h)
        normalized = Execution::Usage.normalize(requests: observations.fetch("requests"), complete: observations.dig("completion", "accounting_complete") == true)
        observations["usage"] = normalized
        diagnostic = if status != "success"
          provider_status = execution.fetch("stdout", "").scan(/Provider request failed with HTTP (\d{3})/).flatten.last
          {"type" => "sandbox", "message" => provider_status ? "provider_http_#{provider_status}" : execution["error"] || "sandbox_execution_#{status}"}
        end
        Result.new(status: status, outputs: (status == "success") ? {"repository" => exported} : {},
          duration: execution["duration"], usage: normalized["usage"], session_id: observations["session_id"],
          error: (status == "blocked") ? {"type" => "sandbox", "message" => "sandbox_evidence_incomplete"} : diagnostic,
          logs: {"sandbox" => evidence, "launch" => @launch.to_h, "execution" => observations,
                 "partial_export" => (status == "success") ? nil : execution["export"],
                 "binary_output_base64" => execution["binary_output_base64"],
                 "stdout" => execution["stdout"], "stderr" => execution["stderr"], "error" => execution["error"]}, retry_safe: false)
      rescue ArgumentError, KeyError, SystemCallError => error
        Result.new(status: "blocked", outputs: {}, error: {"type" => "sandbox", "message" => error.class.name}, logs: {}, retry_safe: false)
      end
    end
  end
end
