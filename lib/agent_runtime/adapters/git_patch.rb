require "tmpdir"
require_relative "process_runner"

module AgentRuntime
  module Adapters
    # Separate temporary Git metadata keeps the caller's index and HEAD untouched.
    class GitPatch
      def initialize(repository, runner: ProcessRunner.new)
        @repository, @runner = repository, runner
      end

      def capture
        Dir.mktmpdir("agru-patch-") do |directory|
          @git = directory
          initialized = @runner.call(argv: ["git", "init", "--bare", directory], cwd: directory, timeout: 10)
          raise ArgumentError, "Git patch initialization failed" unless initialized["status"] == "success"
          run("add", "--all", "--force", "--", ".")
          before = run("write-tree").strip
          result = yield
          run("add", "--all", "--force", "--", ".")
          patch = run("diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", before, "--")
          [result, patch]
        end
      end

      private

      def run(*arguments)
        result = @runner.call(argv: ["git", "--git-dir=#{@git}", "--work-tree=#{@repository}", *arguments],
          cwd: @repository, timeout: 10, env: {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
                                               "GIT_INDEX_FILE" => File.join(@git, "index"), "GIT_OBJECT_DIRECTORY" => File.join(@git, "objects"),
                                               "GIT_COMMON_DIR" => @git, "GIT_CONFIG_COUNT" => "0"})
        raise ArgumentError, "Git patch collection failed: #{result["stderr"]}" unless result["status"] == "success"
        raise ArgumentError, "Git patch exceeds capture limit" if result["stdout"].bytesize >= 1_048_576
        result["stdout"]
      end
    end
  end
end
