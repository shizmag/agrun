require "tmpdir"
require_relative "comparative_experiment"
require_relative "adapters/nl2repo"
require_relative "nl2repo_audited_grader"

module AgentRuntime
  module Benchmarks
    # Reproduction using the same evaluator implementation, not an independent
    # evaluator. Hidden procedures are supplied separately through trusted assets.
    class PortableRegrade
      def run(bundle:, root:, assets:, destination: nil)
        verified = ComparativeExperiment.verify_freeze(bundle)
        payload = JSON.parse(File.read(File.join(bundle, "experiment.json")))
        raise ArgumentError, "new Store directory required" if File.exist?(root)
        destination ||= File.join(root, "portable-regrade.json")
        bundle_path = File.expand_path(bundle)
        [root, destination].each do |path|
          expanded = File.expand_path(path)
          raise ArgumentError, "cannot write inside source bundle" if expanded == bundle_path || expanded.start_with?(bundle_path + File::SEPARATOR)
        end
        raise ArgumentError, "evidence destination exists" if File.exist?(destination)
        store = Store.new(root)
        grader = NL2RepoAuditedGrader.new(store: store, root: assets)
        adapter = Adapters::NL2Repo.new(store: store, root: assets, audited_grader: grader)
        records = payload.fetch("submissions").map do |submission|
          cell = payload.fetch("report").fetch("cells").find { |item| item.fetch("id") == submission.fetch("cell_id") }
          original = cell.fetch("grading_attempts").first.fetch("request")
          artifact = restore(store, submission)
          request = adapter.prepare_grading_request(task: adapter.load_task(cell.fetch("task_id")), submission: artifact, limits: original.fetch("limits"))
          %w[benchmark task_id specification_digest expected_nodeids audited_binding].each do |key|
            raise ArgumentError, "portable grading identity mismatch: #{key}" unless request.fetch(key) == original.fetch(key)
          end
          result = adapter.grade_submission(request)
          {"cell_id" => cell.fetch("id"), "submission_digest" => artifact.fetch("digest"), "request" => request,
           "result" => result, "matches_original" => %w[score verdict execution_status protocol quality_basis].all? { |key| result[key] == cell[key] }}
        end
        evidence = {"schema" => "agru-portable-regrade-v1", "source_freeze" => verified,
                    "semantics" => "same-implementation evaluator reproduction; not independent evaluator semantics",
                    "cells" => records, "verified" => !records.empty? && records.all? { |record| record.fetch("matches_original") }}
        FileUtils.mkdir_p(File.dirname(destination))
        File.write(destination, JSON.pretty_generate(evidence) + "\n")
        evidence
      end

      private

      def restore(store, submission)
        Dir.mktmpdir("portable-submission-") do |directory|
          submission.fetch("repository_manifest").each do |entry|
            path = File.join(directory, entry.fetch("path"))
            FileUtils.mkdir_p(File.dirname(path))
            File.binwrite(path, entry.fetch("content").unpack1("m0"))
            File.chmod(entry.fetch("executable") ? 0o755 : 0o644, path)
          end
          artifact = Submission.new(store: store).capture(repository: directory, run_id: "portable-regrade")
          raise ArgumentError, "restored submission digest mismatch" unless artifact.fetch("digest") == submission.fetch("submission_digest")
          artifact
        end
      end
    end
  end
end
