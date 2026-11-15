require "json"
require "digest"
require "open3"
require "pathname" # standard:disable Lint/RedundantRequireStatement

# Offline candidate identity only. Acceptance belongs to post-commit evidence gates.
module M12cs3EnvironmentFreeze
  BINDINGS = %w[agent_binary sandbox_config tools plugins lsp mcp mock_relay_contract model_catalog benchmark_revision task_manifest audited_v2_grader export_contract resources_deadline scientific_protocol].freeze
  GATES = %w[a_pass b_pass post_commit_fresh_parity semantic_architectures_1_3_3 immutable_submission_grade_regrade writer_quiescent_export effective_environment_verified no_execution_changes].freeze

  def self.release(root, candidate, evidence, review)
    validate(root, candidate)
    raise ArgumentError, "evidence identity mismatch" unless evidence.fetch("candidate_sha256") == candidate.fetch("sha256") && evidence.fetch("runtime_commit") == candidate.fetch("runtime_commit")
    raise ArgumentError, "mock evidence is not live capability" unless evidence.fetch("evidence_kind") == "installed_mock" && evidence.fetch("capability_claim") == false
    raise ArgumentError, "release gates incomplete" unless evidence.fetch("gates").keys.sort == GATES.sort && evidence.fetch("gates").values.all? { |value| value == true }
    artifacts = evidence.fetch("artifacts")
    raise ArgumentError, "missing artifact digests" unless artifacts.is_a?(Hash) && !artifacts.empty? && artifacts.values.all? { |sha| sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/) }
    raise ArgumentError, "independent review required" unless review.fetch("verdict") == "pass" && review.fetch("independent") == true && review.fetch("reviewer").is_a?(String) && !review.fetch("reviewer").empty? && review.fetch("reviewer") != review.fetch("producer") && review.fetch("evidence_sha256") == digest(evidence)
    payload = {"schema_version" => 1, "status" => "accepted", "scope" => "installed_mock_infrastructure_only", "candidate_sha256" => candidate.fetch("sha256"), "evidence_sha256" => digest(evidence), "review_sha256" => digest(review), "runtime_commit" => candidate.fetch("runtime_commit")}
    payload.merge("sha256" => digest(payload))
  end

  def self.validate_release(root, candidate, evidence, review, attestation)
    raise ArgumentError, "release attestation mismatch" unless release(root, candidate, evidence, review) == attestation
    true
  end

  def self.git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise ArgumentError, out unless status.success?
    out.strip
  end

  def self.canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def self.create(root, spec)
    root = File.realpath(root)
    raise ArgumentError, "repository root required" unless File.realpath(git(root, "rev-parse", "--show-toplevel")) == root
    raise ArgumentError, "dirty repository" unless git(root, "status", "--porcelain", "--untracked-files=all").empty?
    raise ArgumentError, "mock evidence cannot be relabeled" unless spec.fetch("evidence_kind", "installed_mock") == "installed_mock"
    raise ArgumentError, "unexpected requested model" unless spec.fetch("requested_model") == "cx/gpt-6-luna-low"
    raise ArgumentError, "image must be digest pinned" unless spec.fetch("image").match?(/\A(?:sha256:|[^\s]+@sha256:)[0-9a-f]{64}\z/)
    bindings = BINDINGS.to_h do |key|
      path = spec.fetch(key)
      raise ArgumentError, "invalid binding path" unless path.is_a?(String) && !Pathname.new(path).absolute? && path.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }
      actual = File.realpath(File.join(root, path))
      raise ArgumentError, "binding escapes repository" unless actual.start_with?(root + "/") && File.file?(actual)
      raise ArgumentError, "binding must be tracked" if git(root, "ls-files", "--", path).empty?
      [key, {"path" => path, "sha256" => Digest::SHA256.file(actual).hexdigest}]
    end
    payload = {"schema_version" => 1, "status" => "candidate", "evidence_kind" => "installed_mock", "runtime_commit" => git(root, "rev-parse", "HEAD"), "image" => spec.fetch("image"), "requested_model" => spec.fetch("requested_model"), "architectures" => {"single_agent" => 1, "fixed_workflow" => 3, "dsl" => 3}, "bindings" => bindings}
    payload.merge("sha256" => digest(payload))
  end

  def self.validate(root, manifest)
    payload = manifest.except("sha256")
    raise ArgumentError, "stale manifest digest" unless digest(payload) == manifest.fetch("sha256")
    spec = manifest.fetch("bindings").transform_values { |binding| binding.fetch("path") }
    %w[image requested_model evidence_kind].each { |key| spec[key] = manifest.fetch(key) }
    raise ArgumentError, "freeze differs from clean checkout" unless create(root, spec) == manifest
    true
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    operation, root, input = ARGV
    raise ArgumentError, "usage: create|validate ROOT INPUT.json" unless ARGV.length == 3
    document = JSON.parse(File.read(input))
    case operation
    when "create" then puts JSON.pretty_generate(M12cs3EnvironmentFreeze.create(root, document))
    when "validate" then M12cs3EnvironmentFreeze.validate(root, document)
                         puts "candidate identity valid; acceptance not asserted"
    else raise ArgumentError, "unknown operation"
    end
  rescue ArgumentError, KeyError, SystemCallError, JSON::ParserError => e
    warn e.message
    exit 1
  end
end
