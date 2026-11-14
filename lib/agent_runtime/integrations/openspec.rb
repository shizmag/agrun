require "json"
require "fileutils"
require_relative "../adapters/process_runner"

module AgentRuntime
  module Integrations
    # Optional external CLI; requiring this file neither executes nor installs it.
    class OpenSpec
      def initialize(workspace:, runner: Adapters::ProcessRunner.new, executable: "openspec")
        @workspace, @runner, @executable = File.expand_path(workspace), runner, executable
      end

      def inspect(item: nil, type: "spec", timeout: 30)
        args = item ? ["show", safe_item(item), "--type", safe_type(type), "--json", "--no-interactive"] : ["list", "--specs", "--json"]
        invoke(args, timeout)
      end

      def validate(item: nil, type: "spec", timeout: 30)
        args = ["validate", "--strict", "--json", "--no-interactive"]
        args.concat(item ? [safe_item(item), "--type", safe_type(type)] : ["--all"])
        invoke(args, timeout)
      end

      def status(change:, timeout: 30)
        invoke(["status", "--change", safe_item(change), "--json"], timeout)
      end

      def instructions(change:, artifact: "apply", timeout: 30)
        invoke(["instructions", safe_item(artifact), "--change", safe_item(change), "--json"], timeout)
      end

      def import_artifacts(change:, store:, run_id:)
        root = File.join(@workspace, "openspec", "changes", safe_item(change))
        raise ArgumentError, "missing or symlinked change directory" unless File.directory?(root) && !File.symlink?(root)
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
          raise ArgumentError, "symlinked OpenSpec artifact" if File.symlink?(path)
          next unless File.file?(path)
          store.put(type: "text", value: File.read(path), run_id: run_id, step_id: "openspec-import", attempt: 1, metadata: {"source" => path.delete_prefix(root + "/"), "change" => change})
        end
      end

      # Imports plain spec text, never overwrites existing material or follows a
      # destination symlink. Validation is a separate explicit local CLI action.
      def import(source:, name:)
        name = safe_item(name)
        source = File.expand_path(source)
        raise ArgumentError, "source must be a regular file" unless File.file?(source)
        parent = File.join(@workspace, "openspec", "specs")
        [@workspace, File.join(@workspace, "openspec"), parent].each do |path|
          raise ArgumentError, "symlink destination is not allowed" if File.symlink?(path)
        end
        FileUtils.mkdir_p(parent)
        destination = File.join(parent, name)
        Dir.mkdir(destination) # exclusive: existing paths are not overwritten
        File.write(File.join(destination, "spec.md"), File.read(source), mode: "wx")
        {"name" => name, "path" => File.join(destination, "spec.md")}
      end

      private

      def safe_item(value)
        raise ArgumentError, "invalid OpenSpec name" unless value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/)
        value
      end

      def safe_type(value)
        raise ArgumentError, "type must be spec or change" unless %w[spec change].include?(value)
        value
      end

      def invoke(args, timeout)
        result = @runner.call(argv: [@executable, *args], cwd: @workspace, timeout: timeout,
          env: {"OPENSPEC_TELEMETRY" => "0", "DO_NOT_TRACK" => "1"})
        result["data"] = JSON.parse(result["stdout"]) unless result["stdout"].strip.empty?
        result
      rescue JSON::ParserError => error
        result.merge("status" => "unknown", "error" => "invalid OpenSpec JSON: #{error.message}")
      end
    end
  end
end
