require_relative "../adapters/process_runner"
require_relative "submission"

module AgentRuntime
  module Benchmarks
    # Runs an adapter-selected, immutable plan. Execution success is NOT a score.
    class ContainerGrader
      class Plan
        COMMANDS = {"nl2repo" => "/opt/agru/bin/grade-nl2repo".freeze}.freeze
        attr_reader :image, :command

        def initialize(image:, command:)
          unless image.is_a?(String) && image.match?(/\A[a-z0-9][a-z0-9._\/-]*(?::[0-9]+)?(?:\/[a-z0-9._-]+)*@sha256:[a-f0-9]{64}\z/)
            raise ArgumentError, "grading image must be pinned by sha256 digest"
          end
          raise ArgumentError, "grading command is not allowlisted" unless COMMANDS.key?(command)
          @image = image.dup.freeze
          @command = COMMANDS.fetch(command)
          freeze
        end
      end

      def initialize(store:, process_runner: Adapters::ProcessRunner.new)
        @submissions = Submission.new(store: store)
        @runner = process_runner
      end

      def grade(submission:, plan:, limits:, cancellation: nil)
        validate_limits!(limits)
        raise ArgumentError, "trusted grading plan required" unless plan.instance_of?(Plan)
        name = "agru-grade-#{SecureRandom.hex(16)}"
        evidence = {"execution_status" => "error", "result_authority" => "untrusted", "container_name" => name, "image_digest" => plan.image, "resource_policy" => limits.dup}
        Dir.mktmpdir("agru-grading-") do |root|
          snapshot = File.join(root, "submission")
          attempted = false
          begin
            artifact = @submissions.verify(submission)
            @submissions.materialize(artifact, destination: snapshot)
            argv = ["docker", "run", "--name", name, "--pull=never", "--read-only", "--network=none", "--user=65534:65534", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--cpus=#{limits.fetch("cpus")}", "--memory=#{limits.fetch("memory_bytes")}", "--memory-swap=#{limits.fetch("memory_bytes")}", "--pids-limit=#{limits.fetch("pids")}", "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=#{limits.fetch("tmpfs_bytes")},mode=1777", "--mount", "type=bind,src=#{snapshot},dst=/submission,readonly,bind-propagation=rprivate", "--workdir=/submission", "--entrypoint", plan.command, plan.image]
            argv << "/submission" # Explicitly override any image CMD.
            attempted = true
            raw = @runner.call(argv: argv, cwd: root, timeout: limits.fetch("timeout_seconds"), cancellation: cancellation, env: docker_env)
            %w[status stdout stderr exit_code duration stdout_truncated stderr_truncated].each { |key| evidence[key] = raw[key] }
            evidence["execution_status"] = execution_status(raw)
            @submissions.verify(artifact)
            @submissions.verify_snapshot!(artifact, snapshot)
            evidence["submission_id"] = artifact.fetch("id")
            evidence["submission_digest"] = artifact.fetch("digest")
          rescue => e
            evidence["execution_status"] = "error"
            evidence["error"] = "#{e.class}: #{e.message}"
          ensure
            if attempted
              begin
                cleanup = @runner.call(argv: ["docker", "rm", "--force", name], cwd: root, timeout: 10, env: docker_env)
                raise Error, "container cleanup failed: #{cleanup.inspect}" unless cleanup["status"] == "success" && cleanup["exit_code"] == 0
              rescue => e
                evidence["execution_status"] = "error"
                evidence["cleanup_error"] = "#{e.class}: #{e.message}"
              end
            end
          end
        end
        evidence
      end

      private

      def docker_env
        {"DOCKER_HOST" => nil, "DOCKER_CONTEXT" => nil, "DOCKER_TLS_VERIFY" => nil, "DOCKER_CERT_PATH" => nil}
      end

      def execution_status(raw)
        return raw["status"] if %w[timeout cancelled].include?(raw["status"])
        return "error" unless raw["status"] == "success" && raw["exit_code"] == 0 && !raw["stdout_truncated"] && !raw["stderr_truncated"]
        "success"
      end

      def validate_limits!(limits)
        keys = %w[cpus memory_bytes pids timeout_seconds tmpfs_bytes]
        raise ArgumentError, "exact resource limits required" unless limits.is_a?(Hash) && limits.keys.sort == keys.sort
        keys.each do |key|
          value = limits[key]
          valid = value.is_a?(Numeric) && value.real? && value.finite? && value.positive?
          valid &&= value.is_a?(Integer) if %w[memory_bytes pids tmpfs_bytes].include?(key)
          raise ArgumentError, "#{key} must be positive and finite" unless valid
        end
      end
    end
  end
end
