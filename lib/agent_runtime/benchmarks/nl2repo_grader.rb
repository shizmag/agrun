require "json"
require "securerandom"
require "digest"
require_relative "nl2repo_image"

module AgentRuntime
  module Benchmarks
    # Authorized, task-specific diagnostic transport. Never a quality authority.
    # No solver repository or private assets are exported to the host.
    class NL2RepoGrader
      IMAGE = "#{NL2RepoImage::REPOSITORY}@#{NL2RepoImage::APPROVED_DIGEST}"

      def initialize(process_runner: AgentRuntime::Adapters::ProcessRunner.new)
        @runner = process_runner
      end

      def diagnose(script:, root:, timeout: 120, reference_archive: nil, submission_repository: nil)
        raise ArgumentError, "bounded diagnostic timeout required" unless (1..300).cover?(timeout)
        name = "agru-retrying-diagnostic-#{SecureRandom.hex(12)}"
        argv = ["docker", "run", "--name", name, "--pull=never", "--platform=linux/amd64",
          "--network=none", "--cpus=1", "--memory=512m", "--memory-swap=512m", "--pids-limit=64",
          "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only",
          "--tmpfs=/tmp:rw,nosuid,nodev,size=134217728", "--env=PYTHONDONTWRITEBYTECODE=1",
          "--entrypoint=/bin/sh", IMAGE, "-c", script]
        if reference_archive
          path = File.expand_path(reference_archive)
          unless path.include?("/.agru/nl2repo/reference/") && File.file?(path) && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == "345da8c5765bd982b1d1915deb9102fd3d1f7ad16bd84a9700b85f64d24e8f3e"
            raise ArgumentError, "verified private retrying reference archive required"
          end
          argv.insert(2, "--mount", "type=bind,src=#{path},dst=/reference.tar.gz,readonly")
        end
        if submission_repository
          path = File.realpath(submission_repository)
          raise ArgumentError, "invalid submission mount path" if path.include?(",")
          argv.insert(2, "--mount", "type=bind,src=#{path},dst=/submission,readonly")
        end
        begin
          result = @runner.call(argv: argv, cwd: root, timeout: timeout)
          evidence = result.merge("result_authority" => "untrusted_diagnostic", "official_score" => nil,
            "execution_status" => "unavailable", "score" => nil, "verdict" => nil,
            "image" => IMAGE, "platform" => NL2RepoImage::PLATFORM, "argv" => argv)
        ensure
          begin
            cleanup = @runner.call(argv: ["docker", "rm", "--force", name], cwd: root, timeout: 15)
          rescue => error
            cleanup = {"status" => "error", "stderr" => "#{error.class}: #{error.message}"}
          end
          if evidence
            evidence["cleanup"] = cleanup
            evidence["cleanup_failed"] = cleanup["status"] != "success" || (!cleanup["exit_code"].nil? && cleanup["exit_code"] != 0)
            evidence["cleanup_error"] = cleanup if evidence["cleanup_failed"]
          end
        end
      end
    end
  end
end
