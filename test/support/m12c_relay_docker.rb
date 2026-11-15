require "securerandom"
require "tmpdir"
require_relative "../../lib/agent_runtime/adapters/process_runner"

# Explicitly opt-in mock-only infrastructure; not a production sandbox API.
class M12cRelayDocker
  IMAGE = "node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20".freeze
  attr_reader :relay_volume, :image

  def initialize(script: "default")
    negative_script = ["native-host-negative", "redirect-negative"].include?(script)
    raise ArgumentError, "unknown frozen mock script" unless negative_script || ["default", "native-subagent", "s2-parity"].include?(script)
    @script = script
    @image = IMAGE
    @prefix = "agru-mock-#{SecureRandom.hex(8)}"
    @relay_volume = "#{@prefix}-relay"
    @upstream_volume = "#{@prefix}-upstream"
    @containers = []
    @volumes = []
  end

  def command(*args)
    timeout = 15.0
    if @startup_deadline
      timeout = [timeout, @startup_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
      raise "mock startup deadline exceeded" unless timeout.positive?
    end
    result = AgentRuntime::Adapters::ProcessRunner.new.call(
      argv: ["docker", *args], cwd: Dir.pwd, timeout: timeout
    )
    unless result.fetch("status") == "success"
      raise "docker failed (#{result["status"]}): #{result["stderr"]}"
    end
    result.fetch("stdout")
  end

  def start
    raise "mock helper already started" if @root || @closed
    @startup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    @root = Dir.mktmpdir("agru-mock-relay-")
    File.chmod(0o755, @root)
    File.write(File.join(@root, "credential"), "mock-only-#{SecureRandom.hex(16)}", mode: "w", perm: 0o444)
    [@relay_volume, @upstream_volume].each do |v|
      command("volume", "create", v)
      @volumes << v
    end
    command(*(base + ["--rm", "--cap-add=CHOWN", "-v", "#{@relay_volume}:/relay", "-v", "#{@upstream_volume}:/upstream",
      @image, "node", "-e", "const f=require('fs');for(const p of ['/relay','/upstream']){f.chmodSync(p,0o700);f.chownSync(p,65534,65534)}"]))
    launch("mock", ["#{@upstream_volume}:/upstream"])
    launch("relay", ["#{@upstream_volume}:/upstream", "#{@relay_volume}:/relay"])
    self
  ensure
    @startup_deadline = nil
  end

  def agent_argv
    base + ["--rm", "--user=65534:65534", "--mount", "type=volume,src=#{@relay_volume},dst=/relay,readonly", @image]
  end

  def logs(role)
    command("logs", "#{@prefix}-#{role}")
  end

  # Test-owned bridge-network service: positive calibration then network-none denial.
  def start_canary
    name = "#{@prefix}-canary"
    @containers << name
    script = <<~JS
      const net=require('net'),udp=require('dgram').createSocket('udp4');
      net.createServer(s=>{console.log('tcp-received');s.end('canary')}).listen(18081,'0.0.0.0');
      udp.on('message',(b,r)=>{console.log('udp-received');udp.send(b,r.port,r.address)});
      udp.bind(18082,'0.0.0.0');
    JS
    command("run", "-d", "--pull=never", "--name", name, "--network=bridge",
      "--user=65534:65534", "--cap-drop=ALL", "--read-only", @image, "node", "-e", script)
    command("inspect", "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", name).strip
  end

  def close
    return if @closed
    errors = []
    @containers.reverse_each do |name|
      command("rm", "-f", name)
      @containers.delete(name)
    rescue => e
      errors << e.message
    end
    @volumes.reverse_each do |name|
      command("volume", "rm", name)
      @volumes.delete(name)
    rescue => e
      errors << e.message
    end
    if @root && File.directory?(@root)
      File.unlink(File.join(@root, "credential"))
      Dir.rmdir(@root)
    end
    raise "mock cleanup incomplete: #{errors.join("; ")}" unless errors.empty?
    @closed = true
  end

  private

  def base
    ["run", "--pull=never", "--network=none", "--read-only", "--cap-drop=ALL",
      "--security-opt=no-new-privileges", "--pids-limit=64", "--memory=128m", "--cpus=1"]
  end

  def launch(role, volumes)
    name = "#{@prefix}-#{role}"
    @containers << name
    mounts = volumes.flat_map { |v| ["-v", v] }
    asset = File.expand_path("m12c_mock_relay.cjs", __dir__)
    if @script == "s2-parity"
      fixture = File.expand_path("m12cs2_parity_fixture.cjs", __dir__)
      mounts += ["-v", "#{fixture}:/m12cs2_parity_fixture.cjs:ro"]
    end
    command(*(base + ["-d", "--user=65534:65534", "--name", name] + mounts +
      ["-v", "#{asset}:/helper.cjs:ro", "-v", "#{@root}:/secret:ro", @image, "node", "/helper.cjs", role, @script]))
    100.times do
      return if logs(role).include?(%("ready":"#{role}"))
      sleep 0.05
    end
    raise "mock readiness timeout"
  end
end
