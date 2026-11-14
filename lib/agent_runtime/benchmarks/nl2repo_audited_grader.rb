require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "securerandom"
require_relative "nl2repo_grader"
require_relative "submission"
require_relative "audited_results"
require_relative "nl2repo_audited_promotion"
require_relative "nl2repo_test_manifest"

module AgentRuntime
  module Benchmarks
    # Offline transport for controlled ordinary submissions. The structured file
    # is independent of stdout, NOT authenticated against malicious Python.
    class NL2RepoAuditedGrader
      SOURCE_PATH = File.expand_path(__FILE__).freeze
      SOURCE_SHA256 = Digest::SHA256.file(SOURCE_PATH).hexdigest.freeze
      ROOT = File.expand_path("../../..", __dir__)
      REFERENCE_REVISION = "1d5699348d707e377aad7488da6a8a1b48a65933"
      REFERENCE_SHA256 = "d8f1cc7e269fe908cae965fb9338d3625c56c9e56a35435dcb6f78ee74a53e0a"
      TEST_SHA256 = "6d6286fc485273ba8b434afbf3f754f3f69321281bd94fd1f08b88a9171e056f"
      HELPER = File.join(ROOT, "script/nl2repo_audited_collector.py")
      POLICY = {"platform" => "linux/amd64", "network" => "none", "cpu" => 1, "memory_mb" => 512, "pids" => 64, "timeout" => 120, "user" => "65534:65534"}.freeze

      def initialize(store:, root: File.join(ROOT, ".agru/nl2repo"), process_runner: AgentRuntime::Adapters::ProcessRunner.new)
        @store = store
        @root = root
        @runner = process_runner
        @receipts = {}
      end

      def container_argv(name:, trusted:, submission:)
        ["docker", "run", "--name", name, "--pull=never", "--platform=linux/amd64",
          "--network=none", "--cpus=1", "--memory=512m", "--memory-swap=512m", "--pids-limit=64",
          "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only", "--user=65534:65534",
          "--tmpfs=/tmp:rw,nosuid,nodev,size=134217728,mode=1777", "--env=PYTHONDONTWRITEBYTECODE=1",
          "--mount", "type=bind,src=#{trusted},dst=/trusted,readonly",
          "--mount", "type=bind,src=#{submission},dst=/submission,readonly",
          "--mount", "type=bind,src=#{File.dirname(trusted)}/results,dst=/results",
          "--entrypoint=/bin/sh", NL2RepoGrader::IMAGE, "-c", self.class.preparation_script]
      end

      def self.preparation_script
        <<~SH
          set -eu
          mkdir -p /tmp/candidate /tmp/private /tmp/results
          echo '#{TEST_SHA256}  /workspace/test_retrying.py' | sha256sum -c -
          python -c 'import sys,pytest,six; assert sys.version_info[:3] == (3,10,11); assert pytest.__version__ == "8.4.1"; assert six.__version__ == "1.17.0"'
          cp -R /submission/. /tmp/candidate/
          cp /workspace/test_retrying.py /tmp/private/test_retrying.py
          cd /tmp/candidate
          export PYTHONPATH=/tmp/candidate
          export PYTEST_DISABLE_PLUGIN_AUTOLOAD=1
          exec python /trusted/collector.py --binding /trusted/binding.json --output /results/report.json -- --rootdir=/tmp/private --confcutdir=/tmp/private -c /dev/null -p no:cacheprovider /tmp/private/test_retrying.py
        SH
      end

      def identity
        [self.class, AuditedResults, NL2RepoAuditedPromotion].each do |source|
          unless Digest::SHA256.file(source::SOURCE_PATH).hexdigest == source::SOURCE_SHA256
            raise Error, "audited grading source changed after load; restart required: #{source::SOURCE_PATH}"
          end
        end
        {"transport_sha256" => SOURCE_SHA256,
         "collector_sha256" => Digest::SHA256.file(HELPER).hexdigest,
         "validator_sha256" => AuditedResults::SOURCE_SHA256,
         "promotion_sha256" => NL2RepoAuditedPromotion::SOURCE_SHA256,
         "image" => NL2RepoGrader::IMAGE, "resource_policy" => POLICY}
      end

      def grade(submission:, binding:, expected_nodeids:, request:)
        identity
        cases = NL2RepoTestManifest.new
        raise ArgumentError, "unexpected test population" unless expected_nodeids == cases.expected_nodeids
        record = {"protocol" => "nl2repo-audited-v2", "binding" => binding, "expected_binding" => binding,
                  "expected_nodeids" => expected_nodeids, "execution_status" => "error"}
        attempt = SecureRandom.uuid
        record["attempt_id"] = attempt
        Dir.mktmpdir("agru-audited-attempt-") do |work|
          snapshot = File.join(work, "candidate")
          Submission.new(store: @store).materialize(submission, destination: snapshot)
          reference = File.join(work, "reference")
          FileUtils.mkdir_p(reference)
          source = File.join(@root, "reference", "original-#{REFERENCE_REVISION}", "retrying.py")
          raise ArgumentError, "verified private reference unavailable" unless File.file?(source) && !File.symlink?(source) && Digest::SHA256.file(source).hexdigest == REFERENCE_SHA256
          FileUtils.cp(source, File.join(reference, "retrying.py"))
          File.chmod(0o755, work, reference, snapshot)
          record["candidate_inventory"] = {"submission_digest" => submission.fetch("digest"),
            "missing_required_module" => %w[retrying.py retrying].none? { |path| File.exist?(File.join(snapshot, path)) || File.symlink?(File.join(snapshot, path)) },
            "checked_paths" => %w[retrying.py retrying]}
          reference_binding = binding.merge("attempt_id" => attempt, "role" => "reference", "reference_sha256" => REFERENCE_SHA256)
          candidate_binding = binding.merge("attempt_id" => attempt, "role" => "candidate")
          reference_raw = execute(repository: reference, binding: reference_binding)
          record["reference"] = parse_raw(reference_raw, expected_nodeids, reference_binding)
          record["reference_evidence"] = persist_raw(reference_raw, attempt, "reference")
          candidate_raw = execute(repository: snapshot, binding: candidate_binding)
          identity
          record["candidate"] = parse_raw(candidate_raw, expected_nodeids, candidate_binding)
          record["candidate_evidence"] = persist_raw(candidate_raw, attempt, "candidate")
          record["execution_status"] = if %w[timeout cancelled].include?(candidate_raw.dig("process", "status"))
            candidate_raw.dig("process", "status")
          elsif candidate_raw["report_bytes"] && reference_raw["report_bytes"]
            "success"
          else
            "error"
          end
        end
        issue_receipt(request, record)
      rescue => error
        record ||= {"protocol" => "nl2repo-audited-v2", "execution_status" => "error"}
        record["reason"] = "#{error.class}: #{error.message}"
        issue_receipt(request, record)
      end

      def consume_evidence(request:, evidence:)
        receipt = @receipts.delete(evidence.object_id)
        return unless receipt && receipt.fetch("request").equal?(request) && receipt.fetch("evidence").equal?(evidence)
        receipt.fetch("record")
      end

      def parse_raw(raw, nodeids, binding)
        AuditedResults.parse(bytes: raw["report_bytes"], expected_nodeids: nodeids,
          expected_binding: binding, process: raw["process"])
      end

      def persist_raw(raw, attempt, role)
        metadata = raw.except("report_bytes")
        if raw["report_bytes"]
          metadata["report_artifact"] = @store.put(type: "text", value: raw.fetch("report_bytes"),
            run_id: attempt, step_id: "#{role}-structured-report", attempt: 1)
        end
        artifact = @store.put(type: "json", value: metadata, run_id: attempt, step_id: "#{role}-process-evidence", attempt: 1)
        {"report_artifact" => metadata["report_artifact"], "process_artifact" => artifact,
         "report_sha256" => raw["report_sha256"], "process" => raw["process"], "cleanup" => raw["cleanup"]}
      end

      def issue_receipt(request, record)
        evidence = {"receipt_id" => SecureRandom.uuid}.freeze
        @receipts[evidence.object_id] = {"request" => request, "evidence" => evidence, "record" => record}
        evidence
      end

      # Raw transport only: policy validation and promotion are separate.
      def execute(repository:, binding:, cancellation: nil)
        name = "agru-audited-#{SecureRandom.hex(12)}"
        evidence = {"binding" => binding, "container_name" => name, "resource_policy" => POLICY,
                    "image" => NL2RepoGrader::IMAGE}
        Dir.mktmpdir("agru-audited-") do |work|
          trusted = File.join(work, "trusted")
          FileUtils.mkdir_p(trusted)
          results = File.join(work, "results")
          FileUtils.mkdir_p(results)
          File.chmod(0o777, results)
          FileUtils.cp(HELPER, File.join(trusted, "collector.py"))
          unless Digest::SHA256.file(File.join(trusted, "collector.py")).hexdigest == binding.fetch("collector_digest")
            raise Error, "audited collector source changed since request; prepare a new grading request"
          end
          File.write(File.join(trusted, "binding.json"), JSON.generate(binding))
          File.chmod(0o755, work, trusted)
          Dir.children(trusted).each { |entry| File.chmod(0o444, File.join(trusted, entry)) }
          begin
            result = @runner.call(argv: container_argv(name: name, trusted: trusted, submission: repository),
              cwd: work, timeout: POLICY.fetch("timeout"), cancellation: cancellation)
            evidence["process"] = result
            destination = File.join(work, "report.json")
            copy = @runner.call(argv: ["docker", "cp", "#{name}:/results/report.json", destination], cwd: work, timeout: 15)
            evidence["report_copy"] = copy
            if copy["status"] == "success" && File.file?(destination) && !File.symlink?(destination) && File.size(destination) <= 4 * 1024 * 1024
              evidence["report_bytes"] = File.binread(destination)
              evidence["report_sha256"] = Digest::SHA256.hexdigest(evidence.fetch("report_bytes"))
            end
          ensure
            cleanup = @runner.call(argv: ["docker", "rm", "-f", name], cwd: work, timeout: 15)
            evidence["cleanup"] = cleanup
          end
        end
        evidence
      rescue => error
        evidence.merge("error" => "#{error.class}: #{error.message}")
      end
    end
  end
end
