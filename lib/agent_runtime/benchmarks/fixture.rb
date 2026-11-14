require "fileutils"
require "json"
require "open3"
require "securerandom"

module AgentRuntime
  module Benchmarks
    Task = Struct.new(:id, :instruction, :repository, :base_commit, :dataset_revision, :spec, :hidden_test, :dataset, :public_tests, :limits, :metadata)

    module Manifest
      def self.load(path)
        data = JSON.parse(File.read(path))
        required = %w[id dataset dataset_revision repository base_commit instruction public_tests external_evaluation limits metadata spec]
        missing = required.reject { |key| data.key?(key) }
        raise ArgumentError, "missing manifest fields: #{missing.join(", ")}" unless missing.empty?
        raise ArgumentError, "base_commit must be a Git object ID" unless data["base_commit"].is_a?(String) && data["base_commit"].match?(/\A[0-9a-f]{40,64}\z/)
        root = File.dirname(File.expand_path(path))
        Task.new(id: data["id"], dataset: data["dataset"], instruction: data["instruction"], repository: File.expand_path(data["repository"], root), base_commit: data["base_commit"], dataset_revision: data["dataset_revision"], spec: data["spec"], hidden_test: File.expand_path(data.fetch("external_evaluation").fetch("procedure"), root), public_tests: data["public_tests"], limits: data["limits"], metadata: data["metadata"])
      end
    end

    # A real, local Git baseline. Hidden evaluation material is never copied here.
    class Fixture
      ROOT = File.expand_path("../../..", __dir__)

      def self.demo(root:)
        repository = File.expand_path(File.join(root, "repository"))
        raise ArgumentError, "fixture destination already exists: #{repository}" if File.exist?(repository)

        FileUtils.mkdir_p(repository)
        FileUtils.cp_r(File.join(ROOT, "benchmarks/fixtures/demo/source/."), repository)
        git(repository, "init", "--quiet")
        git(repository, "add", ".")
        git(repository, "-c", "user.name=Benchmark Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "demo baseline")
        commit = git(repository, "rev-parse", "HEAD").strip
        manifest = JSON.parse(File.read(File.join(ROOT, "benchmarks/fixtures/demo/manifest.json")))
        manifest["base_commit"] = commit
        manifest["repository"] = repository
        manifest["external_evaluation"] = {"procedure" => File.join(ROOT, "benchmarks/fixtures/demo/hidden_test.rb")}
        File.write(File.join(root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
        Manifest.load(File.join(root, "manifest.json"))
      end

      def self.git(repository, *args)
        output, error, status = Open3.capture3({"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_AUTHOR_DATE" => "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2000-01-01T00:00:00Z"}, "git", "-C", repository, *args)
        raise "git #{args.first} failed: #{error}" unless status.success?
        output
      end
    end
  end
end
