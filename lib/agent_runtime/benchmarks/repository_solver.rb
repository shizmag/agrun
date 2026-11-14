require_relative "adapter"

module AgentRuntime
  module Benchmarks
    # A deterministic submission control, not a task-solving or scoring agent.
    class RepositorySolver
      def initialize(repository: nil)
        if repository
          source = File.expand_path(repository)
          # Validate before resolving aliases or copying any user-controlled tree.
          raise ArgumentError, "repository must be a directory" unless File.directory?(source)
          raise ArgumentError, "repository path is a symlink" if File.symlink?(source)
          validate_source!(source)
          @manifest = Store.manifest(source)
          @digest = Digest::SHA256.hexdigest(IR.dump(@manifest))
          Adapter.freeze_json(@manifest)
        end
      end

      def configuration
        {"category" => "repository-submission", "provenance" => @manifest ? "explicit local repository" : "deterministic repository control", "source_digest" => @digest, "live" => false}
      end

      def solve(task:, model:, budget:, workspace:)
        Adapter.public_task(task)
        repository = File.join(File.expand_path(workspace), "repository")
        raise ArgumentError, "prepared repository required" unless File.directory?(repository)
        if @manifest
          raise ArgumentError, "repository changed" unless Digest::SHA256.hexdigest(IR.dump(@manifest)) == @digest
          snapshot = File.join(File.expand_path(workspace), "local-submission")
          Store.materialize(@manifest, snapshot)
          repository = snapshot
        else
          File.write(File.join(repository, "README.md"), "# Deterministic repository submission\n\nThis offline control does not implement the requested task.\n")
        end
        {"status" => "success", "repository" => repository, "model" => model, "usage" => nil, "cost" => nil}
      end

      private

      def validate_source!(directory)
        Dir.children(directory).each do |name|
          raise ArgumentError, "unsafe repository path" if name.include?("\\")
          path = File.join(directory, name)
          stat = File.lstat(path)
          raise ArgumentError, "repository aliases and special files are forbidden" if !stat.directory? && !(stat.file? && stat.nlink == 1)
          validate_source!(path) if stat.directory?
        end
      end
    end
  end
end
