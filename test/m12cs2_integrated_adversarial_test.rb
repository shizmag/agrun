require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require "digest"
require "json"

class M12cs2IntegratedAdversarialTest < Minitest::Test
  LIMITS = {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}.freeze
  IMAGE = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1".freeze

  def setup
    skip "explicit Docker export opt-in required" unless ENV["AGRU_S2_EXPORT_DOCKER"] == "1"
  end

  def test_actual_truncated_archive_never_accepted
    require_relative "../lib/agent_runtime/execution/sandbox_archive_transport"
    transport = AgentRuntime::Execution::SandboxArchiveTransport.new
    observed = nil
    wrapper = Object.new
    wrapper.define_singleton_method(:call) do |**args|
      if args[:argv].last == "/control/archive.tar"
        argv = args[:argv].take(5) + ["/usr/bin/python3", "-I", "-S", "-c",
          'import sys; f=open("/control/archive.tar","rb"); sys.stdout.buffer.write(f.read(512))']
        observed = transport.call(**args.merge(argv: argv))
      else
        transport.call(**args)
      end
    end
    Dir.mktmpdir do |workspace|
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_S2_EXPORT_IMAGE", IMAGE), limits: LIMITS)
      result = nil
      AgentRuntime::Execution::SandboxArchiveTransport.stub(:new, -> { wrapper }) do
        result = boundary.call(argv: ["/bin/sh", "-c", "echo data > file"], workspace: workspace, timeout: 20)
      end
      refute_nil observed, "actual archive stream was not reached"
      assert_equal "success", observed.fetch("status"), observed.inspect
      assert_equal 512, observed.fetch("bytes")
      assert_equal "failure", result.fetch("status"), result.inspect
      assert_match(/archive|truncat|incomplete/i, result.fetch("error"), result.inspect)
      refute result.key?("export"), result.inspect
      assert_equal true, result.dig("cleanup", "confirmed"), result.inspect
    end
  end

  def test_agent_parent_escape_does_not_export_outside_workspace
    Dir.mktmpdir do |workspace|
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_S2_EXPORT_IMAGE", IMAGE), limits: LIMITS)
      script = "echo outside > ../outside-probe 2>/dev/null || true; echo inside > inside-probe"
      result = boundary.call(argv: ["/bin/sh", "-c", script], workspace: workspace, timeout: 20)
      assert_equal "success", result.fetch("status"), result.inspect
      exported = result.fetch("export").fetch("path")
      assert_equal "inside\n", File.read(File.join(exported, "inside-probe"))
      refute File.exist?(File.join(exported, "outside-probe"))
      assert_equal true, result.dig("cleanup", "confirmed"), result.inspect
    ensure
      FileUtils.remove_entry(File.dirname(exported)) if exported && File.directory?(File.dirname(exported))
    end
  end

  def test_excessive_output_entries_fail_closed_after_agent_completion
    Dir.mktmpdir do |workspace|
      boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_S2_EXPORT_IMAGE", IMAGE), limits: LIMITS.merge("workspace_entries" => 5))
      code = "import pathlib; [pathlib.Path('file'+str(i)).write_text('x') for i in range(8)]"
      result = boundary.call(argv: ["/usr/bin/python3", "-c", code], workspace: workspace, timeout: 20)
      assert_equal "failure", result["status"], result.inspect
      assert_match(/entry limit/i, result.fetch("error"), result.inspect)
      refute result.key?("export"), result.inspect
      assert_equal true, result.dig("cleanup", "confirmed"), result.inspect
    end
  end

  {
    "normal" => nil,
    "background" => "pass",
    "detached" => "os.setsid()",
    "open_fd" => "os.setsid()",
    "repeated_write" => "pass",
    "refuse_term" => "signal.signal(signal.SIGTERM, signal.SIG_IGN)"
  }.each do |scenario, setup|
    define_method("test_#{scenario}_integrated_quiescent_export") do
      Dir.mktmpdir do |workspace|
        code = if setup.nil?
          "open('/workspace/writes', 'w').write('normal-completion')"
        else
          <<~PYTHON
            import os, signal, time
            if os.fork() == 0:
                #{setup}
                f = open('/workspace/writes', 'w')
                while True:
                    f.write('x'); f.flush(); time.sleep(.002)
            while not os.path.exists('/workspace/writes') or os.path.getsize('/workspace/writes') < 2:
                time.sleep(.002)
          PYTHON
        end
        boundary = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_S2_EXPORT_IMAGE", IMAGE), limits: LIMITS)
        result = boundary.call(argv: ["/usr/bin/python3", "-c", code], workspace: workspace, timeout: 20)
        assert_equal "success", result["status"], result.inspect
        assert_equal 0, result["exit_code"], result.inspect
        assert_equal true, result.dig("cleanup", "confirmed"), result.inspect
        assert_equal true, result.dig("cleanup", "private_confirmed"), result.inspect
        export = result.fetch("export")
        exported = export.fetch("path")
        content = File.binread(File.join(exported, "writes"))
        setup.nil? ? assert_equal("normal-completion", content) : assert_operator(content.bytesize, :>=, 2)
        expected = Digest::SHA256.hexdigest(JSON.generate(export.fetch("manifest")))
        assert_equal expected, export.fetch("digest")
        assert_includes export.fetch("manifest").to_s, Digest::SHA256.hexdigest(content)
        before = Digest::SHA256.file(File.join(exported, "writes")).hexdigest
        sleep 0.1
        assert_equal before, Digest::SHA256.file(File.join(exported, "writes")).hexdigest
        _, _, inspect_status = Open3.capture3("docker", "inspect", result.fetch("container_name"))
        refute inspect_status.success?, "container still exists after accepted export"
      ensure
        FileUtils.remove_entry(File.dirname(exported)) if exported && File.directory?(File.dirname(exported))
      end
    end
  end
end
