require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_image"

class NL2RepoImageTest < Minitest::Test
  def test_default_transport_can_be_constructed_when_adapter_namespace_exists
    require_relative "../../lib/agent_runtime/benchmarks/adapters/nl2repo"
    in_tmp do |root|
      image = AgentRuntime::Benchmarks::NL2RepoImage.new(root: root)
      refute image.prepare(task: "retrying", allow_download: false, dry_run: true).fetch("grading_ready")
    end
  end

  def test_submission_bridge_checks_local_image_and_remains_scoreless_without_download
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |**args|
      calls << args
      stdout = if args.fetch(:argv)[1] == "image"
        JSON.generate([{"Os" => "linux", "Architecture" => "amd64", "RepoDigests" => ["#{AgentRuntime::Benchmarks::NL2RepoImage::REPOSITORY}@#{AgentRuntime::Benchmarks::NL2RepoImage::APPROVED_DIGEST}"]}])
      else
        "23 passed"
      end
      {"status" => "success", "stdout" => stdout, "stderr" => "", "exit_code" => 0}
    end
    in_tmp do |root|
      image = AgentRuntime::Benchmarks::NL2RepoImage.new(root: root, process_runner: runner)
      result = image.diagnose_submission(task: "retrying", repository: root,
        limits: {"max_grading_seconds" => 120, "max_solver_seconds" => 60, "max_output_bytes" => 1_048_576})
      assert_equal %w[image run rm], calls.map { |call| call.fetch(:argv)[1] }
      assert_equal "unavailable", result.fetch("execution_status")
      assert_nil result.fetch("score")
      assert_equal "untrusted_diagnostic", result.fetch("result_authority")
      assert_equal 120, calls[1].fetch(:timeout)
      assert_includes calls[1].fetch(:argv).join(" "), "dst=/submission,readonly"
      refute result.fetch("cleanup_failed")
    end
  end

  def test_no_download_or_dry_run_never_calls_docker
    runner = Object.new
    def runner.call(**)
      raise "unexpected Docker access"
    end
    in_tmp do |root|
      image = AgentRuntime::Benchmarks::NL2RepoImage.new(root: root, process_runner: runner)
      assert_raises(ArgumentError) { image.prepare(task: "retrying", allow_download: false) }
      assert_equal "not_acquired", image.prepare(task: "retrying", allow_download: true, dry_run: true).fetch("status")
      assert_raises(ArgumentError) { image.prepare(task: "unknown", allow_download: true) }
    end
  end

  def test_resolves_platform_before_pull_and_verifies_digest
    digest = AgentRuntime::Benchmarks::NL2RepoImage::APPROVED_DIGEST
    reference = "#{AgentRuntime::Benchmarks::NL2RepoImage::REPOSITORY}@#{digest}"
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |**args|
      calls << args
      output = case args.fetch(:argv)[1]
      when "manifest"
        {"Descriptor" => {"digest" => digest, "platform" => {"os" => "linux", "architecture" => "amd64"}}}
      when "image"
        [{"Os" => "linux", "Architecture" => "amd64", "RepoDigests" => [reference], "Id" => "sha256:local", "Size" => 100}]
      else "pulled"
      end
      {"status" => "success", "stdout" => JSON.generate(output), "stderr" => ""}
    end
    in_tmp do |root|
      receipt = AgentRuntime::Benchmarks::NL2RepoImage.new(root: root, process_runner: runner).prepare(task: "retrying", allow_download: true)
      assert_equal %w[manifest pull image], calls.map { |call| call.fetch(:argv)[1] }
      assert_equal ["docker", "pull", "--platform=linux/amd64", reference], calls[1].fetch(:argv)
      assert_equal false, receipt.fetch("grading_ready")
      assert_equal reference, JSON.parse(File.read(File.join(root, "retrying-image.json"))).fetch("image")
    end
  end

  def test_wrong_platform_and_registry_failure_do_not_pull_or_write_receipt
    [
      {"status" => "error", "stderr" => "denied", "stdout" => ""},
      {"status" => "timeout", "stderr" => "", "stdout" => ""},
      {"status" => "success", "stderr" => "", "stdout" => JSON.generate({"Descriptor" => {"digest" => "sha256:#{"b" * 64}", "platform" => {"os" => "linux", "architecture" => "amd64"}}})},
      {"status" => "success", "stderr" => "", "stdout" => JSON.generate({"Descriptor" => {"digest" => "sha256:#{"b" * 64}", "platform" => {"os" => "linux", "architecture" => "arm64"}}})}
    ].each do |response|
      calls = []
      runner = Object.new
      runner.define_singleton_method(:call) do |**args|
        calls << args
        response
      end
      in_tmp do |root|
        image = AgentRuntime::Benchmarks::NL2RepoImage.new(root: root, process_runner: runner)
        assert_raises(ArgumentError) { image.prepare(task: "retrying", allow_download: true) }
        assert_equal 1, calls.length
        refute File.exist?(File.join(root, "retrying-image.json"))
      end
    end
  end
end
