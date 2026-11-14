require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/nl2repo_audited_grader"

class NL2RepoAuditedTransportTest < Minitest::Test
  def test_container_policy_is_offline_nonroot_and_resource_bounded
    grader = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: nil)
    argv = grader.container_argv(name: "test-attempt", trusted: "/private/trusted", submission: "/private/candidate")
    %w[--pull=never --platform=linux/amd64 --network=none --read-only --user=65534:65534 --cpus=1 --memory=512m --pids-limit=64 --cap-drop=ALL --security-opt=no-new-privileges].each do |flag|
      assert_includes argv, flag
    end
    assert_includes argv, AgentRuntime::Benchmarks::NL2RepoGrader::IMAGE
    assert_includes argv, "type=bind,src=/private/trusted,dst=/trusted,readonly"
    assert_includes argv, "type=bind,src=/private/candidate,dst=/submission,readonly"
    refute_includes argv, "--privileged"
    refute_includes argv, "--rm" # report is copied before explicit cleanup
  end

  def test_candidate_preparation_never_overlays_original_implementation
    script = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.preparation_script
    assert_includes script, "mkdir -p /tmp/candidate /tmp/private /tmp/results"
    assert_includes script, "cp -R /submission/. /tmp/candidate/"
    assert_includes script, "/workspace/test_retrying.py"
    assert_includes script, "cp /workspace/test_retrying.py /tmp/private/test_retrying.py"
    refute_match(/cp[^\n]*\/workspace\/\*/, script)
    refute_match(/pip install/, script)
    assert_includes script, "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1"
    assert_includes script, "--confcutdir=/tmp/private"
    assert_includes script, "--rootdir=/tmp/private"
  end

  def test_identity_binds_the_result_validator_and_score_promotion_sources
    identity = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: nil).identity
    %w[validator promotion].each do |component|
      file = (component == "validator") ? "audited_results.rb" : "nl2repo_audited_promotion.rb"
      assert_equal Digest::SHA256.file(File.expand_path("../../lib/agent_runtime/benchmarks/#{file}", __dir__)).hexdigest,
        identity.fetch("#{component}_sha256")
    end
  end

  def test_actual_transport_copies_report_from_its_container_before_cleanup
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |**args|
      calls << args
      argv = args.fetch(:argv)
      File.write(argv.last, '{"controlled":"report"}') if argv[1] == "cp"
      {"status" => "success", "exit_code" => 0, "stdout" => "23 passed", "stderr" => ""}
    end
    Dir.mktmpdir do |repository|
      result = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: nil, process_runner: runner).execute(repository: repository, binding: {"attempt" => "unique", "collector_digest" => Digest::SHA256.file(AgentRuntime::Benchmarks::NL2RepoAuditedGrader::HELPER).hexdigest})
      assert_equal %w[run cp rm], calls.map { |call| call.fetch(:argv)[1] }
      name = result.fetch("container_name")
      assert_equal "#{name}:/results/report.json", calls[1].fetch(:argv)[2]
      assert_equal name, calls[2].fetch(:argv).last
      assert_equal '{"controlled":"report"}', result.fetch("report_bytes")
      assert_equal Digest::SHA256.hexdigest(result.fetch("report_bytes")), result.fetch("report_sha256")
      assert_equal "unique", result.fetch("binding").fetch("attempt")
    end
  end

  def test_missing_report_and_timeout_do_not_reuse_a_previous_report
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |**args|
      calls << args.fetch(:argv)
      {"status" => (args.fetch(:argv)[1] == "run") ? "timeout" : "failure", "exit_code" => nil}
    end
    Dir.mktmpdir do |repository|
      result = AgentRuntime::Benchmarks::NL2RepoAuditedGrader.new(store: nil, process_runner: runner).execute(repository: repository, binding: {"collector_digest" => Digest::SHA256.file(AgentRuntime::Benchmarks::NL2RepoAuditedGrader::HELPER).hexdigest})
      assert_equal "timeout", result.fetch("process").fetch("status")
      refute result.key?("report_bytes")
      assert_equal %w[run cp rm], calls.map { |argv| argv[1] }
      assert_equal "failure", result.fetch("cleanup").fetch("status")
    end
  end
end
