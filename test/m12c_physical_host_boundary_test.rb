require_relative "test_helper"
require "socket"
require "json"
require_relative "support/m12c_relay_docker"
require_relative "../lib/agent_runtime/execution/sandbox_runner"

# Finite Docker Desktop/macOS calibration, not a claim about arbitrary plugins
# or kernel exploits. No provider, Internet destination, or real secret is used.
class M12cPhysicalHostBoundaryTest < Minitest::Test
  def test_host_listener_and_host_material_are_available_only_to_positive_controls
    skip "set AGRU_M12C_HOST_BOUNDARY=1 for physical macOS Docker acceptance" unless ENV["AGRU_M12C_HOST_BOUNDARY"] == "1"
    assert_equal "darwin", RUBY_PLATFORM[/darwin/], "this calibration specifically requires a physical macOS host"
    listener = TCPServer.new("0.0.0.0", 0)
    port = listener.addr[1]
    accepted = Queue.new
    serving = Thread.new do
      loop do
        client = listener.accept
        accepted << true
        client.write("synthetic-host-listener\n")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    in_tmp do |root|
      secret = File.join(root, "hidden-procedure-canary")
      File.write(secret, "synthetic-hidden-material")
      assert_equal "synthetic-hidden-material", File.read(secret)
      workspace = File.join(root, "workspace")
      Dir.mkdir(workspace)
      File.write(File.join(workspace, "visible"), "synthetic-workspace-positive")
      probe = <<~JS
        const net=require('node:net'),fs=require('node:fs');
        const socket=net.connect({host:'host.docker.internal',port:#{port}});
        let reached=false;
        socket.on('data',b=>{reached=b.toString().includes('synthetic-host-listener');socket.destroy()});
        socket.on('error',()=>{});
        setTimeout(()=>{
          socket.destroy();
          console.log(JSON.stringify({reached,visible:fs.readFileSync('/workspace/visible','utf8'),
            hidden:fs.existsSync(#{secret.to_json}),dockerSocket:fs.existsSync('/var/run/docker.sock')}));
        },1200);
      JS
      helper = M12cRelayDocker.new
      positive = JSON.parse(helper.command("run", "--rm", "--pull=never", "--network=bridge",
        "-v", "#{workspace}:/workspace:ro", helper.image, "node", "-e", probe))
      assert_equal true, positive.fetch("reached"), "bridge control must reach actual macOS listener"
      assert_equal 1, accepted.size
      runner = AgentRuntime::Execution::SandboxRunner.new(image: ENV.fetch("AGRU_M12C_AGENT_IMAGE"),
        limits: {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216})
      result = runner.call(argv: ["/usr/local/bin/node", "-e", probe], workspace: workspace, timeout: 15)
      assert_equal 0, result.fetch("exit_code"), result.inspect
      assert_equal true, result.fetch("cleanup").fetch("confirmed")
      assert_equal "none", result.fetch("container_inspect").fetch("HostConfig").fetch("NetworkMode")
      negative = JSON.parse(result.fetch("stdout"))
      assert_equal false, negative.fetch("reached")
      assert_equal "synthetic-workspace-positive", negative.fetch("visible")
      assert_equal false, negative.fetch("hidden")
      assert_equal false, negative.fetch("dockerSocket")
      assert_equal 1, accepted.size, "sandbox must not create a second host connection"
    ensure
      FileUtils.remove_entry(result["export_directory"]) if result && result["export_directory"] && File.directory?(result["export_directory"])
    end
  ensure
    listener&.close
    serving&.join(2)
    serving&.kill
  end
end
