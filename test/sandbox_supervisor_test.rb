require "minitest/autorun"
require "open3"
require "tmpdir"
require "json"
require "securerandom"

class SandboxSupervisorTest < Minitest::Test
  IMAGE = "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1"
  HELPER = File.expand_path("../lib/agent_runtime/execution/sandbox_supervisor.py", __dir__)

  def test_unreadable_input_directory_fails_closed_instead_of_omitting_subtree
    Dir.mktmpdir do |input|
      nested = File.join(input, "unreadable")
      Dir.mkdir(nested)
      File.write(File.join(nested, "evidence"), "must not disappear")
      File.chmod(0, nested)
      with_container("pass", input: input, start: false) do |name|
        sleep 0.3
        assert_equal "", docker!("logs", name)
        assert_equal "false", docker!("inspect", "--format", "{{.State.Running}}", name).strip
      end
    ensure
      File.chmod(0o700, nested) if nested
    end
  end

  def test_provisioning_preserves_private_modes_and_agent_can_edit_inputs
    Dir.mktmpdir do |input|
      File.write(File.join(input, "private"), "original")
      File.chmod(0o600, File.join(input, "private"))
      File.write(File.join(input, "normal"), "original")
      File.chmod(0o644, File.join(input, "normal"))
      payload = "import os; assert os.stat('/workspace/private').st_uid == 65534; assert os.stat('/workspace/private').st_mode & 0o777 == 0o600; open('/workspace/private','w').write('edited'); open('/workspace/normal','w').write('edited')"
      payload += "; assert not any('/input/' in os.readlink('/proc/self/fd/'+fd) for fd in os.listdir('/proc/self/fd') if os.path.exists('/proc/self/fd/'+fd))"
      with_container(payload, input: input) do |name|
        wait_ready(name)
        assert_equal 0, JSON.parse(docker!("exec", name, "cat", "/control/status.json")).fetch("exit_code")
        assert_equal "edited", docker!("exec", name, "/bin/sh", "-c", "tar -xOf /control/archive.tar ./private")
        assert_equal "original", File.read(File.join(input, "private"))
      end
    end
  end

  def test_ordinary_completion_exports_private_file_as_ustar
    with_container("open('/workspace/private', 'w').write('ok'); __import__('os').chmod('/workspace/private', 0o600)") do |name|
      wait_ready(name)
      archive = docker!("exec", name, "cat", "/control/archive.tar")
      assert_equal "ustar\0", archive.byteslice(257, 6)
      assert_equal "0", archive.byteslice(512 + 156, 1)
      assert_equal "ok", docker!("exec", name, "/bin/sh", "-c", "tar -xOf /control/archive.tar ./private")
    end
  end

  def test_forced_cleanup_has_no_readiness_and_container_disappearance_loses_tmpfs
    with_container("import time; open('/workspace/marker', 'w').write('tmpfs'); time.sleep(100)") do |name|
      sleep 0.2
      assert_equal "", docker!("logs", name)
      docker!("kill", name)
      assert_equal "", docker!("logs", name)
      _, _, status = Open3.capture3("docker", "exec", name, "cat", "/control/archive.tar")
      refute status.success?, "stopped container must not permit tmpfs export"
      docker!("start", name)
      _, _, status = Open3.capture3("docker", "exec", name, "test", "-e", "/workspace/marker")
      refute status.success?, "workspace tmpfs contents must disappear across stop/start"
      _, _, status = Open3.capture3("docker", "exec", name, "test", "-e", "/control/start")
      refute status.success?, "control tmpfs readiness trigger must disappear across stop/start"
      docker!("kill", name)
      docker!("rm", name)
      _, _, status = Open3.capture3("docker", "inspect", name)
      refute status.success?, "removed container must not remain exportable"
    end
  end

  def test_control_tmpfs_exhaustion_never_publishes_readiness
    with_container("import os; f=open('/workspace/large','wb'); f.write(os.urandom(2*1024*1024)); f.close()", control_size: "1m") do |name|
      docker!("wait", name)
      assert_equal "", docker!("logs", name)
    end
  end

  {"background_writer" => "", "detached_writer" => "os.setsid()",
   "term_refusing_writer" => "signal.signal(signal.SIGTERM, signal.SIG_IGN)"}.each do |scenario, setup|
    define_method("test_#{scenario}_open_descriptor_is_stopped_before_export") do
      payload = <<~PYTHON
        import os, signal, time
        if os.fork() == 0:
            #{setup.empty? ? "pass" : setup}
            f = open('/workspace/writes', 'w')
            while True:
                f.write('x'); f.flush(); time.sleep(.005)
        while not os.path.exists('/workspace/writes'): time.sleep(.005)
        time.sleep(.03)
      PYTHON
      with_container(payload) do |name|
        wait_ready(name)
        before = docker!("exec", name, "sha256sum", "/workspace/writes")
        sleep 0.1
        assert_equal before, docker!("exec", name, "sha256sum", "/workspace/writes")
        assert_operator docker!("exec", name, "wc", "-c", "/workspace/writes").to_i, :>, 1
      end
    end
  end

  def test_detached_term_resistant_writer_is_dead_before_export
    skip "set AGRU_SUPERVISOR_DOCKER_TEST=1 for actual Docker test" unless ENV["AGRU_SUPERVISOR_DOCKER_TEST"] == "1"
    name = "agru-supervisor-test-#{SecureRandom.hex(6)}"
    payload = <<~PYTHON
      import os, signal, time, json
      print('{"protocol":1,"quiescent":true}', flush=True)
      os.write(2, b'{"protocol":1,"quiescent":true}\\n')
      time.sleep(.2)
      status = open('/proc/self/status').read()
      open('/workspace/identity', 'w').write(status)
      open('/workspace/private', 'w').write('private content')
      os.chmod('/workspace/private', 0o600)
      try:
          open('/control/status.json', 'w').write('forged')
          raise RuntimeError('agent accessed trusted control directory')
      except PermissionError: pass
      try:
          open('/proc/1/fd/1', 'w').write('forged readiness')
          raise RuntimeError('agent accessed supervisor stdout')
      except PermissionError: pass
      try:
          open('/proc/1/mem', 'rb')
          raise RuntimeError('agent accessed supervisor memory')
      except PermissionError: pass
      try:
          os.kill(1, signal.SIGKILL)
          raise RuntimeError('agent signalled supervisor')
      except PermissionError: pass
      if os.fork() == 0:
          os.setsid()
          if os.fork() != 0: os._exit(0)
          signal.signal(signal.SIGTERM, signal.SIG_IGN)
          f = open('/workspace/writer', 'w')
          f.write('started'); f.flush()
          while True:
              f.write('x'); f.flush(); time.sleep(.005)
      while not os.path.exists('/workspace/writer'): time.sleep(.005)
    PYTHON
    docker!("run", "-d", "--name", name, "--network", "none", "--read-only", "--user", "0:0",
      "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
      "--security-opt", "no-new-privileges:true", "--pids-limit", "32", "--memory", "128m",
      "--tmpfs", "/workspace:rw,nosuid,nodev,noexec,size=16m,mode=1777,uid=65534,gid=65534",
      "--tmpfs", "/control:rw,nosuid,nodev,noexec,size=16m,mode=0700",
      "--mount", "type=bind,src=#{HELPER},dst=/supervisor.py,readonly",
      "--entrypoint", "/usr/bin/python3", IMAGE, "-I", "-S", "/supervisor.py", "/usr/bin/python3", "-c", payload)
    docker!("exec", "--user", "0:0", name, "/usr/bin/touch", "/control/start")
    status = nil
    100.times do
      text, _, result = Open3.capture3("docker", "logs", name)
      if result.success? && !text.empty?
        assert_equal({"protocol" => 1, "quiescent" => true}, JSON.parse(text))
        status = JSON.parse(docker!("exec", "--user", "0:0", name, "cat", "/control/status.json"))
        break
      end
      sleep 0.05
    end
    assert_equal({"protocol" => 1, "exit_code" => 0, "quiescent" => true}, status)
    assert_includes docker!("exec", name, "cat", "/control/agent.stdout"), '"quiescent":true'
    assert_equal "private content", docker!("exec", name, "/bin/sh", "-c", "tar -xOf /control/archive.tar ./private")
    pids = docker!("exec", name, "/bin/sh", "-c", "ls -d /proc/[0-9]*")
    assert_operator pids.lines.size, :<=, 3
    identity = docker!("exec", name, "cat", "/workspace/identity")
    assert_match(/^Uid:\s+65534\s+65534\s+65534\s+65534$/, identity)
    assert_match(/^CapEff:\s+0000000000000000$/, identity)
    assert_match(/^CapPrm:\s+0000000000000000$/, identity)
    assert_match(/^CapAmb:\s+0000000000000000$/, identity)
    assert_match(/^NoNewPrivs:\s+1$/, identity)
    before = docker!("exec", name, "sha256sum", "/workspace/writer", "/control/archive.tar")
    sleep 0.15
    assert_equal before, docker!("exec", name, "sha256sum", "/workspace/writer", "/control/archive.tar")
    _, _, denied = Open3.capture3("docker", "exec", "--user", "65534:65534", name, "cat", "/control/status.json")
    refute denied.success?
  ensure
    Open3.capture3("docker", "rm", "-f", name) if name
  end

  private

  def with_container(payload, control_size: "16m", input: nil, start: true)
    skip "set AGRU_SUPERVISOR_DOCKER_TEST=1 for actual Docker test" unless ENV["AGRU_SUPERVISOR_DOCKER_TEST"] == "1"
    name = "agru-supervisor-test-#{SecureRandom.hex(6)}"
    input_mount = input ? ["--mount", "type=bind,src=#{input},dst=/input,readonly"] : []
    docker!("run", "-d", "--name", name, *input_mount, "--network", "none", "--read-only", "--user", "0:0",
      "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "KILL",
      "--security-opt", "no-new-privileges:true", "--pids-limit", "32", "--memory", "128m",
      "--tmpfs", "/workspace:rw,nosuid,nodev,noexec,size=16m,mode=1777,uid=65534,gid=65534",
      "--tmpfs", "/control:rw,nosuid,nodev,noexec,size=#{control_size},mode=0700",
      "--mount", "type=bind,src=#{HELPER},dst=/supervisor.py,readonly",
      "--entrypoint", "/usr/bin/python3", IMAGE, "-I", "-S", "/supervisor.py", "/usr/bin/python3", "-c", payload)
    docker!("exec", "--user", "0:0", name, "/usr/bin/touch", "/control/start") if start
    yield name
  ensure
    Open3.capture3("docker", "rm", "-f", name) if name
  end

  def wait_ready(name)
    100.times do
      text = docker!("logs", name)
      return if text == "{\"protocol\": 1, \"quiescent\": true}\n"
      sleep 0.05
    end
    flunk "trusted readiness was not published"
  end

  def docker!(*args)
    out, err, status = Open3.capture3("docker", *args)
    assert status.success?, "docker #{args.first}: #{err}"
    out
  end
end
