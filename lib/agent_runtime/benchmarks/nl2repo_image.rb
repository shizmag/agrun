require "json"
require "fileutils"
require_relative "../adapters/process_runner"

module AgentRuntime
  module Benchmarks
    # Acquisition only: this receipt never grants a grading capability.
    class NL2RepoImage
      TAG = "ghcr.io/multimodal-art-projection/nl2repobench/retrying:1.0"
      REPOSITORY = TAG.delete_suffix(":1.0")
      PLATFORM = "linux/amd64"
      APPROVED_DIGEST = "sha256:1302235420db9d34955c42273ebaf23df8bbee31ceeaf3c336347f54b64146fe"

      def initialize(root:, process_runner: AgentRuntime::Adapters::ProcessRunner.new)
        @root = File.expand_path(root)
        @runner = process_runner
      end

      def prepare(task:, allow_download:, dry_run: false)
        raise ArgumentError, "only selected retrying image acquisition is supported" unless task == "retrying"
        receipt = {"task_id" => task, "source_tag" => TAG, "platform" => PLATFORM,
                   "status" => "not_acquired", "grading_ready" => false}
        return receipt if dry_run
        raise ArgumentError, "image download requires explicit allow_download" unless allow_download
        FileUtils.mkdir_p(@root)
        manifest = invoke(["docker", "manifest", "inspect", "--verbose", TAG], timeout: 60)
        entries = manifest.is_a?(Array) ? manifest : [manifest]
        matches = entries.filter_map { |entry|
          descriptor = entry.fetch("Descriptor")
          platform = descriptor.fetch("platform", {})
          descriptor if platform["os"] == "linux" && platform["architecture"] == "amd64"
        }
        raise ArgumentError, "selected image must resolve exactly one linux/amd64 manifest" unless matches.length == 1
        digest = matches.first.fetch("digest")
        raise ArgumentError, "invalid registry manifest digest" unless digest.match?(/\Asha256:[a-f0-9]{64}\z/)
        raise ArgumentError, "registry tag differs from approved selected image digest" unless digest == APPROVED_DIGEST
        image = "#{REPOSITORY}@#{digest}"
        invoke(["docker", "pull", "--platform=#{PLATFORM}", image], timeout: 600, json: false)
        inspection = invoke(["docker", "image", "inspect", image], timeout: 30).fetch(0)
        unless inspection.fetch("Os") == "linux" && inspection.fetch("Architecture") == "amd64" && inspection.fetch("RepoDigests").include?(image)
          raise ArgumentError, "downloaded image platform/digest verification failed"
        end
        receipt.merge!("status" => "image_available_unvalidated", "image" => image,
          "image_id" => inspection.fetch("Id"), "size_bytes" => inspection.fetch("Size"))
        temporary = File.join(@root, "retrying-image.json.tmp-#{Process.pid}")
        File.write(temporary, JSON.pretty_generate(receipt) + "\n", mode: "w", perm: 0o600)
        File.rename(temporary, File.join(@root, "retrying-image.json"))
        receipt
      end

      def diagnose_submission(task:, repository:, limits:)
        raise ArgumentError, "only retrying diagnostics supported" unless task == "retrying"
        require_relative "nl2repo_grader"
        # Local inspection only. No manifest lookup, download or pull.
        inspection = invoke(["docker", "image", "inspect", NL2RepoGrader::IMAGE], timeout: 30).fetch(0)
        unless inspection["Os"] == "linux" && inspection["Architecture"] == "amd64" && inspection.fetch("RepoDigests", []).include?(NL2RepoGrader::IMAGE)
          raise ArgumentError, "verified selected local image required"
        end
        script = <<~SH
          mkdir -p /tmp/candidate /tmp/private
          cp -R /submission/. /tmp/candidate/
          cp /workspace/test_retrying.py /tmp/private/
          cd /tmp/candidate
          echo '=== submitted file hashes ==='
          find . -type f -exec sha256sum {} +
          echo '=== official test hash ==='
          sha256sum /tmp/private/test_retrying.py
          PIP_NO_INDEX=1 PIP_DISABLE_PIP_VERSION_CHECK=1 pip install --no-build-isolation --prefix=/tmp/install -e .
          echo "INSTALL_EXIT=$?"
          PYTHONPATH="$PWD" python -c 'import retrying,hashlib; print(retrying.__file__); print(hashlib.sha256(open(retrying.__file__, "rb").read()).hexdigest())'
          echo "IMPORT_EXIT=$?"
          PYTHONPATH="$PWD" pytest --collect-only -q -p no:cacheprovider /tmp/private/test_retrying.py
          echo "COLLECT_EXIT=$?"
          PYTHONPATH="$PWD" pytest --continue-on-collection-errors -vv -p no:cacheprovider /tmp/private/test_retrying.py
          echo "TEST_EXIT=$?"
        SH
        timeout = [Integer(limits.fetch("max_grading_seconds") { limits.fetch("timeout_seconds") }), 300].min
        NL2RepoGrader.new(process_runner: @runner).diagnose(script: script, root: @root, timeout: timeout,
          submission_repository: repository).merge("procedure_sha256" => Digest::SHA256.hexdigest(script),
            "declared_cases" => 23, "mode" => "clean_diagnostic_not_legacy")
      end

      private

      def invoke(argv, timeout:, json: true)
        result = @runner.call(argv: argv, cwd: @root, timeout: timeout)
        unless result["status"] == "success" && !result["stdout_truncated"] && !result["stderr_truncated"]
          raise ArgumentError, "image acquisition failed (#{argv[1]}): #{result["status"]}: #{result["stderr"]}"
        end
        json ? JSON.parse(result.fetch("stdout")) : result
      end
    end
  end
end
