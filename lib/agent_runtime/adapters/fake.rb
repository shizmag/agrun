require "open3"

module AgentRuntime
  module Adapters
    class Fake
      def execute(request)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        config = request.config
        elapsed = 0.0
        delay = config.fetch("delay", 0).to_f
        while elapsed < delay
          return Result.new(status: "cancelled", outputs: {}) if request.cancellation&.cancelled?
          return Result.new(status: "timeout", outputs: {}, error: {"classification" => "timeout"}) if elapsed >= request.timeout
          sleep([0.005, delay - elapsed].min)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        end
        outputs = config.fetch("values", {}).dup
        case config.fetch("operation", "value")
        when "fail"
          return Result.new(status: "failure", outputs: {}, error: {"classification" => config.fetch("classification", "executor"), "message" => "deterministic fixture failure"})
        when "patch"
          source = request.inputs.fetch("repository")
          destination = File.join(request.workspace, "output")
          before = Store.manifest(source)
          Store.materialize(before, destination)
          config.fetch("files", {}).each do |relative, content|
            raise Error, "unsafe fixture path" if relative.start_with?("/") || relative.split("/").any? { |p| ["..", ".git"].include?(p) }
            path = File.join(destination, relative)
            FileUtils.mkdir_p(File.dirname(path))
            content.nil? ? FileUtils.rm_f(path) : File.write(path, content)
          end
          outputs["repository"] = destination
          # Build a real Git diff against the exact input without modifying it.
          Dir.mktmpdir("agent-runtime-diff") do |git_workspace|
            Store.materialize(before, git_workspace)
            git!(git_workspace, "init", "-q")
            git!(git_workspace, "add", "-A")
            git!(git_workspace, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base", "--allow-empty")
            before.each { |entry| FileUtils.rm_f(File.join(git_workspace, entry["path"])) }
            Store.materialize(Store.manifest(destination), git_workspace)
            git!(git_workspace, "add", "-A")
            outputs["patch"] = git!(git_workspace, "diff", "--cached", "--binary", "--no-ext-diff", "--no-renames")
          end
        when "value", "sleep"
          # Values are already populated; sleep has completed above.
        else raise Error, "unknown fake operation #{config["operation"]}"
        end
        Result.new(status: "success", outputs: outputs, duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, logs: "deterministic fake executor; no model called", usage: nil, cost: nil)
      end

      private

      def git!(directory, *args)
        output, error, status = Open3.capture3("git", "-C", directory, *args)
        raise Error, "fixture Git operation failed: #{error}" unless status.success?
        output
      end
    end
  end
end
