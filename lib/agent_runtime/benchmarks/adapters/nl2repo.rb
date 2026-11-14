require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../adapter"
require_relative "../submission"
require_relative "../nl2repo_image"
require_relative "../nl2repo_audited_promotion"
require_relative "../nl2repo_test_manifest"

module AgentRuntime
  module Benchmarks
    module Adapters
      # Import is an explicit operation. The upstream repository is private grader
      # material, never a solver starting repository or an authenticated score.
      class NL2Repo < Adapter
        SOURCE_PATH = File.expand_path(__FILE__).freeze
        SOURCE_SHA256 = Digest::SHA256.file(SOURCE_PATH).hexdigest.freeze
        ROOT = File.expand_path("../../../..", __dir__)
        STATES = %w[missing downloaded verified images_available grader_ready runnable excluded].freeze
        PUBLIC_KEYS = %w[id benchmark instruction specification_digest metadata availability unavailable_reason].freeze

        attr_reader :dataset_path

        def initialize(manifest_path: File.join(ROOT, "benchmarks/nl2repo/manifest.json"), root: File.join(ROOT, ".agru/nl2repo"), store: nil, diagnostics: false, diagnostic_runner: nil, audited_grader: nil)
          @store = store
          @diagnostics = diagnostics
          @diagnostic_runner = diagnostic_runner
          @audited_grader = audited_grader
          @requests = {}
          @manifest_path = File.expand_path(manifest_path)
          @manifest_bytes = File.binread(@manifest_path)
          @manifest_digest = Digest::SHA256.hexdigest(@manifest_bytes)
          @manifest = JSON.parse(@manifest_bytes)
          import_auditor_schema!
          @root = File.expand_path(root)
          raise ArgumentError, "dataset must live under ignored .agru" unless Pathname.new(@root).each_filename.include?(".agru")
          @dataset_path = File.join(@root, "repository")
          @receipt_path = File.join(@root, "verified.json")
          validate_manifest!
        end

        def identity
          Adapter.freeze_json(JSON.parse(JSON.generate({"name" => "nl2repo", "revision" => @manifest.fetch("revision"), "manifest_digest" => @manifest_digest, "official_score" => "blocked"})))
        end

        def list_tasks
          @manifest.fetch("tasks").map { |record| load_task(record.fetch("id")) }
        end

        def load_task(id)
          record = task_record(id)
          lifecycle = availability
          excluded = record["authorized"] != true && !local_specification_authorized?(record)
          instruction = (!excluded && lifecycle["state"] == "verified") ? File.read(asset_path(record.fetch("instruction_path"))) : nil
          Adapter.public_task({
            "id" => record.fetch("id"), "benchmark" => "nl2repo", "instruction" => instruction,
            "specification_digest" => @manifest.fetch("assets").fetch(record.fetch("instruction_path")),
            "metadata" => {"dataset_revision" => @manifest.fetch("revision"), "manifest_digest" => @manifest_digest},
            "availability" => excluded ? "excluded" : lifecycle.fetch("state"),
            "unavailable_reason" => excluded ? "instruction not authorized for solver use" : lifecycle.fetch("unavailable_reason")
          })
        end

        def availability
          unchanged_manifest!
          state = if !File.exist?(@dataset_path)
            "missing"
          elsif !File.file?(@receipt_path)
            "downloaded"
          else
            verify!
            "verified"
          end
          {"state" => state, "download_bytes" => nil, "disk_bytes" => nil,
           "unavailable_reason" => "official grading blocked: authenticated native collector and controls unavailable"}
        end

        def prepare(dry_run: false, allow_download: false, task: nil, allow_local_specification_use: false)
          if allow_local_specification_use
            raise ArgumentError, "local specification use requires selected task" unless task
            return inspection if dry_run
            unchanged_manifest!
            verify!
            authorization = local_specification_binding(task_record(task))
            receipt = {"authorization" => authorization, "digest" => IR.digest(authorization)}
            path = File.join(@root, "local-specification-use.json")
            raise ArgumentError, "local specification receipt is a symlink" if File.symlink?(path)
            File.write(path, JSON.generate(receipt))
            return availability.merge("local_specification_use" => {"task_id" => task, "redistribution_authorized" => false})
          end
          if task
            unchanged_manifest!
            return NL2RepoImage.new(root: @root).prepare(task: task, allow_download: allow_download, dry_run: dry_run)
          end
          return inspection if dry_run
          unchanged_manifest!
          if File.exist?(@dataset_path) || File.symlink?(@dataset_path)
            verify!
            return availability
          end
          raise ArgumentError, "download requires explicit allow_download" unless allow_download
          raise ArgumentError, "dataset root is a symlink" if File.symlink?(@root)
          FileUtils.mkdir_p(@root)
          git(@root, "clone", "--no-checkout", "--", @manifest.fetch("repository"), @dataset_path)
          git(@dataset_path, "checkout", "--detach", @manifest.fetch("revision"))
          verify_checkout!
          File.write(@receipt_path, JSON.generate({"manifest_digest" => @manifest_digest, "revision" => @manifest.fetch("revision")}))
          availability
        end

        def prepare_solver_workspace(task:, workspace:)
          public_task = authentic_task!(task)
          raise ArgumentError, "task instruction unavailable" unless public_task["availability"] == "verified" && public_task["instruction"].is_a?(String)
          destination = File.expand_path(workspace)
          raise ArgumentError, "solver workspace already exists" if File.exist?(destination) || File.symlink?(destination)
          repository = File.join(destination, "repository")
          FileUtils.mkdir_p(repository)
          git(repository, "init", "-q")
          instruction_path = File.join(destination, "INSTRUCTION.md")
          File.write(instruction_path, public_task.fetch("instruction"))
          {"repository" => repository, "instruction_path" => instruction_path, "task_id" => public_task.fetch("id")}
        end

        def prepare_grading_request(task:, submission:, limits:)
          public_task = authentic_task!(task)
          raise ArgumentError, "Store required for grading requests" unless @store
          artifact = submission.is_a?(String) ? @store.artifact(submission) : submission
          raise ArgumentError, "submission must be a Store repository artifact" unless artifact.is_a?(Hash) && artifact["type"] == "repository"
          stored = @store.artifact(artifact.fetch("id"))
          raise ArgumentError, "submission metadata differs from Store" unless stored == artifact
          artifact = stored
          @store.value(artifact)
          raise ArgumentError, "invalid grading limits" unless limits.is_a?(Hash) && limits.values.all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }
          request = {"benchmark" => identity, "task_id" => public_task.fetch("id"), "specification_digest" => public_task.fetch("specification_digest"),
                     "submission_id" => artifact.fetch("id"), "submission_digest" => artifact.fetch("digest"),
                     "limits" => JSON.parse(JSON.generate(limits)), "protocol_status" => "blocked"}
          if @audited_grader
            verify_loaded_source!
            raise ArgumentError, "audited grading supports only retrying" unless public_task.fetch("id") == "retrying"
            unchanged_manifest!
            cases = NL2RepoTestManifest.new
            unless public_task.fetch("specification_digest") == cases.identity.fetch("specification_sha256") &&
                @manifest.fetch("revision") == cases.identity.fetch("dataset_revision")
              raise ArgumentError, "audited task specification or revision mismatch"
            end
            transport = @audited_grader.identity
            request["expected_nodeids"] = cases.expected_nodeids
            request["audited_binding"] = {
              "protocol" => NL2RepoAuditedPromotion::PROTOCOL, "task_id" => "retrying",
              "submission_digest" => artifact.fetch("digest"),
              "specification_digest" => public_task.fetch("specification_digest"),
              "benchmark_revision" => @manifest.fetch("revision"), "manifest_digest" => @manifest_digest,
              "test_manifest_digest" => cases.digest, "test_source_sha256" => cases.identity.fetch("test_source_sha256"),
              "collector_digest" => transport.fetch("collector_sha256"),
              "procedure_digest" => IR.digest({"protocol" => NL2RepoAuditedPromotion::PROTOCOL,
                                              "transport" => transport.fetch("transport_sha256"),
                                              "validator" => transport.fetch("validator_sha256"),
                                              "promotion" => transport.fetch("promotion_sha256"),
                                              "adapter" => SOURCE_SHA256, "tests" => cases.identity}),
              "environment_digest" => IR.digest(transport.slice("image", "resource_policy")),
              "image" => transport.fetch("image")
            }
            request["protocol_status"] = NL2RepoAuditedPromotion::PROTOCOL
          end
          request["request_digest"] = Digest::SHA256.hexdigest(JSON.generate(request))
          @requests[request.fetch("request_digest")] = JSON.parse(JSON.generate(request))
          Adapter.freeze_json(request)
        end

        def grade_submission(request)
          verify_loaded_source! if @audited_grader
          raise ArgumentError, "unrecognized or modified grading request" unless request.is_a?(Hash) && @requests[request["request_digest"]] == request
          artifact = @store.artifact(request.fetch("submission_id"))
          raise ArgumentError, "submission digest changed" unless artifact.fetch("digest") == request.fetch("submission_digest")
          @store.value(artifact)
          if @audited_grader && request["audited_binding"] && request["expected_nodeids"]
            evidence = @audited_grader.grade(submission: artifact, binding: request.fetch("audited_binding"),
              expected_nodeids: request.fetch("expected_nodeids"), request: request)
            return NL2RepoAuditedPromotion.new(transport: @audited_grader).call(request: request, evidence: evidence)
          end
          # No image probe, Docker pull, native score parsing, or launch can turn
          # an unauthenticated collector into an official grading result.
          result = {"status" => "unavailable", "execution_status" => "unavailable", "verdict" => "untrusted", "trust" => "untrusted", "score" => nil,
                    "reason" => "official NL2Repo grading requires authenticated native collector and isolation controls", "benchmark" => identity}
          if @diagnostics
            raise ArgumentError, "native diagnostics support only selected retrying task" unless request.fetch("task_id") == "retrying"
            boundary = Submission.new(store: @store)
            FileUtils.mkdir_p(File.join(@root, "diagnostics"))
            Dir.mktmpdir("submission-", File.join(@root, "diagnostics")) do |directory|
              repository = File.join(directory, "repository")
              boundary.materialize(artifact, destination: repository)
              helper = @diagnostic_runner || NL2RepoImage.new(root: @root)
              observations = helper.diagnose_submission(task: request.fetch("task_id"), repository: repository, limits: request.fetch("limits"))
              boundary.verify_snapshot!(artifact, repository)
              result["diagnostics"] = IR.normalize_json(observations)
              result["diagnostic_submission_digest"] = artifact.fetch("digest")
            end
          end
          result
        end

        def normalize_score(raw)
          raw if raw.is_a?(Numeric) && raw.finite? && raw.between?(0, 1)
        end

        private

        def verify_loaded_source!
          unless Digest::SHA256.file(SOURCE_PATH).hexdigest == SOURCE_SHA256
            raise Error, "audited grading source changed after load; restart required: #{SOURCE_PATH}"
          end
        end

        def local_specification_binding(record)
          {"schema_version" => 1, "scope" => "local instruction use only; no redistribution or hidden assets",
           "manifest_digest" => @manifest_digest, "revision" => @manifest.fetch("revision"), "task_id" => record.fetch("id"),
           "instruction_path" => record.fetch("instruction_path"),
           "specification_digest" => @manifest.fetch("assets").fetch(record.fetch("instruction_path"))}
        end

        def local_specification_authorized?(record)
          path = File.join(@root, "local-specification-use.json")
          raise ArgumentError, "local specification receipt is a symlink" if File.symlink?(path)
          return false unless File.file?(path)
          receipt = JSON.parse(File.read(path))
          authorization = receipt.fetch("authorization")
          raise ArgumentError, "invalid local specification receipt" unless receipt.keys.sort == %w[authorization digest] && receipt.fetch("digest") == IR.digest(authorization)
          return false unless authorization["task_id"] == record.fetch("id")
          raise ArgumentError, "local specification receipt binding mismatch" unless authorization == local_specification_binding(record)
          true
        rescue JSON::ParserError, KeyError
          raise ArgumentError, "invalid local specification receipt"
        end

        def import_auditor_schema!
          return unless @manifest["benchmark"] == "NL2Repo-Bench"
          official = @manifest.fetch("sources").fetch("official")
          @manifest["benchmark"] = "nl2repo"
          @manifest["repository"] = official.fetch("url")
          @manifest["revision"] = official.fetch("revision")
          @manifest["assets"] = {@manifest.fetch("protocol").fetch("official_grader_path") => @manifest.fetch("protocol").fetch("official_grader_sha256")}
          @manifest.fetch("tasks").each do |record|
            specification = record.fetch("specification")
            record["instruction_path"] = specification.fetch("path")
            record["authorized"] = @manifest.dig("license", "redistribution_authorized") == true
            @manifest.fetch("assets")[specification.fetch("path")] = specification.fetch("sha256")
            record.fetch("metadata_sha256").each do |name, digest|
              @manifest.fetch("assets")[File.join(File.dirname(specification.fetch("path")), name)] = digest
            end
          end
        end

        def inspection
          result = availability
          cached = File.directory?(@dataset_path)
          result.merge(
            "runnable" => false, "grader_status" => "blocked", "score_trust" => "untrusted",
            "launch_plan" => {"status" => "blocked", "reason" => "native overlay inherits reference sources and native regex output is not authenticated; immutable image digests and controls are unavailable", "argv" => nil},
            "planned_actions" => cached ? [] : [{"action" => "clone", "source" => @manifest.fetch("repository"), "revision" => @manifest.fetch("revision"), "requires_opt_in" => true, "network" => @manifest.fetch("repository").match?(/\A(?:https?|ssh|git):/), "download_bytes" => nil}],
            "assets" => @manifest.fetch("assets").map { |path, digest| {"path" => path, "sha256" => digest, "state" => File.file?(File.join(@dataset_path, path)) ? "cached" : "missing", "disk_bytes" => nil} },
            "required_images" => @manifest.fetch("tasks").filter_map do |record|
              image = record["image"]
              next unless image
              {"task_id" => record.fetch("id"), "reference" => image["tag"], "digest" => image["digest"], "platform" => image["platform"],
               "availability" => image["digest"] ? "not_inspected" : "unsupported_unpinned_digest", "pull_requires_opt_in" => true, "disk_bytes" => nil}
            end
          )
        end

        def validate_manifest!
          raise ArgumentError, "unsupported NL2Repo manifest" unless @manifest["schema_version"] == 1 && @manifest["benchmark"] == "nl2repo"
          raise ArgumentError, "revision must be a pinned Git SHA" unless @manifest["revision"].is_a?(String) && @manifest["revision"].match?(/\A[0-9a-f]{40}\z/)
          raise ArgumentError, "repository required" unless @manifest["repository"].is_a?(String) && !@manifest["repository"].empty?
          raise ArgumentError, "assets must be a digest map" unless @manifest["assets"].is_a?(Hash)
          @manifest.fetch("assets").each do |path, digest|
            relative_asset!(path)
            raise ArgumentError, "asset digest must be SHA256" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
          end
          records = @manifest["tasks"]
          raise ArgumentError, "tasks must be an array" unless records.is_a?(Array)
          ids = records.map do |record|
            raise ArgumentError, "task id required" unless record["id"].is_a?(String) && !record["id"].empty?
            path = record["instruction_path"]
            relative_asset!(path)
            raise ArgumentError, "instruction must be digest-pinned" unless @manifest.fetch("assets").key?(path)
            record.fetch("id")
          end
          raise ArgumentError, "duplicate task IDs" unless ids.uniq == ids
        end

        def relative_asset!(path)
          raise ArgumentError, "unsafe asset path" unless path.is_a?(String) && !path.empty? && !path.include?("\0") && !Pathname.new(path).absolute? && path.split("/").none? { |part| ["..", ".", ".git", ""].include?(part) }
        end

        def asset_path(path)
          relative_asset!(path)
          candidate = File.join(@dataset_path, path)
          relative = Pathname.new(candidate).relative_path_from(Pathname.new(@dataset_path)).each_filename.to_a
          relative.inject(@dataset_path) do |parent, component|
            child = File.join(parent, component)
            raise ArgumentError, "symlink asset forbidden" if File.symlink?(child)
            child
          end
          candidate
        end

        def task_record(id)
          @manifest.fetch("tasks").find { |record| record.fetch("id") == id } || raise(KeyError, "unknown NL2Repo task: #{id}")
        end

        def authentic_task!(task)
          raise ArgumentError, "invalid public task" unless task.is_a?(Hash) && (task.keys - PUBLIC_KEYS).empty?
          expected = load_task(task.fetch("id"))
          raise ArgumentError, "public task changed" unless expected == task
          expected
        end

        def unchanged_manifest!
          raise ArgumentError, "pinned manifest changed" unless File.binread(@manifest_path) == @manifest_bytes
        end

        def verify!
          unchanged_manifest!
          raise ArgumentError, "dataset verification receipt missing" unless File.file?(@receipt_path) && !File.symlink?(@receipt_path)
          receipt = JSON.parse(File.read(@receipt_path))
          raise ArgumentError, "dataset manifest pin mismatch" unless receipt == {"manifest_digest" => @manifest_digest, "revision" => @manifest.fetch("revision")}
          verify_checkout!
        end

        def verify_checkout!
          raise ArgumentError, "dataset symlink forbidden" if File.symlink?(@dataset_path) || File.symlink?(File.join(@dataset_path, ".git"))
          raise ArgumentError, "dataset HEAD differs from pinned revision" unless git(@dataset_path, "rev-parse", "HEAD").strip == @manifest.fetch("revision")
          raise ArgumentError, "dataset checkout changed" unless git(@dataset_path, "status", "--porcelain", "--untracked-files=all", "--ignored").empty?
          @manifest.fetch("assets").each do |path, expected|
            candidate = asset_path(path)
            raise ArgumentError, "asset digest mismatch: #{path}" unless File.file?(candidate) && Digest::SHA256.file(candidate).hexdigest == expected
          end
        end

        def git(root, *args)
          output, status = Open3.capture2e({"GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_NOSYSTEM" => "1"}, "git", "-C", root, *args)
          raise ArgumentError, "git operation failed: #{output}" unless status.success?
          output
        end
      end
    end
  end
end
