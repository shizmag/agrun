require_relative "../test_helper"
require "rbconfig"
require_relative "../../lib/agent_runtime/adapters/shell"
require_relative "../../lib/agent_runtime/adapters/open_code_cli"
require_relative "../../lib/agent_runtime/integrations/openspec"

class AdaptersIntegrationTest < Minitest::Test
  def test_openspec_existing_artifacts_become_versioned_inputs
    in_tmp do |dir|
      change = File.join(dir, "openspec/changes/m0")
      FileUtils.mkdir_p(change)
      File.write(File.join(change, "proposal.md"), "# Exact local proposal\n")
      executable = fixture(dir, 'require "json"; puts JSON.generate({"args" => ARGV})')
      integration = AgentRuntime::Integrations::OpenSpec.new(workspace: dir, executable: executable)
      store = AgentRuntime::Store.new(File.join(dir, "store"))
      artifacts = integration.import_artifacts(change: "m0", store: store, run_id: "spec-test")
      assert_equal "# Exact local proposal\n", store.value(artifacts.fetch(0))
      assert_equal "proposal.md", artifacts[0].fetch("metadata").fetch("source")
      assert_equal "success", integration.status(change: "m0")["status"]
      assert_equal "success", integration.instructions(change: "m0")["status"]
      assert_raises(ArgumentError) { integration.import_artifacts(change: "../escape", store: store, run_id: "x") }
    end
  end

  def request(dir, config = {}, timeout: 2, cancellation: nil)
    AgentRuntime::Request.new(inputs: {}, config: config, workspace: dir, timeout: timeout, cancellation: cancellation)
  end

  def runner
    AgentRuntime::Adapters::ProcessRunner.new
  end

  def fixture(dir, body)
    path = File.join(dir, "local executable")
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o700, path)
    path
  end

  def test_shell_has_explicit_argv_no_interpolation_and_captures_status
    in_tmp do |dir|
      value = "$(touch #{dir}/injected); spaces"
      result = AgentRuntime::Adapters::Shell.new.execute(request(dir,
        {"argv" => [RbConfig.ruby, "-e", "STDOUT.write(ARGV[0]); STDERR.write('diagnostic'); exit 7", value]}))
      assert_equal "failure", result.status
      assert_equal value, result.outputs["stdout"]
      assert_equal "diagnostic", result.outputs["stderr"]
      assert_equal 7, result.outputs["exit_code"]
      refute File.exist?(File.join(dir, "injected"))
    end
  end

  def test_missing_executable_and_invalid_argv
    in_tmp do |dir|
      result = runner.call(argv: [File.join(dir, "missing")], cwd: dir, timeout: 1)
      assert_equal "failure", result["status"]
      assert_nil result["exit_code"]
      assert_raises(ArgumentError) { runner.call(argv: "echo unsafe", cwd: dir, timeout: 1) }
    end
  end

  def test_timeout_kills_group_including_term_ignoring_child
    in_tmp do |dir|
      executable = fixture(dir, 'trap("TERM") {}; fork { trap("TERM") {}; sleep 0.7; File.write("escaped", "bad") }; sleep 5')
      result = runner.call(argv: [executable], cwd: dir, timeout: 0.1)
      assert_equal "timeout", result["status"]
      assert_operator result["duration"], :<, 1
      sleep 0.8
      refute File.exist?(File.join(dir, "escaped"))
    end
  end

  def test_cancellation_during_execution
    in_tmp do |dir|
      token = Struct.new(:value) { def cancelled? = value }.new(false)
      thread = Thread.new {
        sleep 0.05
        token.value = true
      }
      result = runner.call(argv: [RbConfig.ruby, "-e", "sleep 4"], cwd: dir, timeout: 2, cancellation: token)
      thread.join
      assert_equal "cancelled", result["status"]
      assert_operator result["duration"], :<, 1
    end
  end

  def test_pre_cancelled_does_not_spawn
    in_tmp do |dir|
      token = Struct.new(:cancelled?).new(true)
      result = runner.call(argv: ["nonexistent"], cwd: dir, timeout: 1, cancellation: token)
      assert_equal "cancelled", result["status"]
    end
  end

  def test_capture_bounded_but_both_streams_drained
    in_tmp do |dir|
      result = runner.call(argv: [RbConfig.ruby, "-e", 'STDOUT.write("a" * 2_000_000); STDERR.write("b" * 2_000_000)'], cwd: dir, timeout: 3)
      assert_equal "success", result["status"]
      assert_equal 1_048_576, result["stdout"].bytesize
      assert_equal 1_048_576, result["stderr"].bytesize
    end
  end

  def test_opencode_blocked_without_opt_in
    in_tmp do |dir|
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: "must-not-run").execute(request(dir))
      assert_equal "blocked", result.status
    end
  end

  def test_opencode_fake_executable_json_events_and_literal_prompt
    in_tmp do |dir|
      executable = fixture(dir, <<~RUBY)
        require "json"
        File.write("argv.json", JSON.generate(ARGV))
        puts JSON.generate(type: "text", sessionID: "ses_fixture", part: {text: "done"})
        puts JSON.generate(type: "step_finish", sessionID: "ses_fixture", part: {tokens: {input: 3, output: 2}, cost: 0.0})
      RUBY
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest).execute(request(dir,
        {"live" => true, "prompt" => "--not-a-flag; $(bad)", "model" => "fixture/local"}))
      assert_equal "success", result.status
      assert_equal "done", result.outputs["text"]
      assert_equal "ses_fixture", result.session_id
      assert_equal 0.0, result.cost
      assert_equal 3, result.usage["steps"].first["input"]
      assert_equal ["--", "--not-a-flag; $(bad)"], JSON.parse(File.read(File.join(dir, "argv.json"))).last(2)
    end
  end

  def test_opencode_malformed_and_incomplete_output_not_success
    in_tmp do |dir|
      executable = fixture(dir, 'puts "not-json"')
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true)
      assert_equal "unknown", adapter.execute(request(dir, {"prompt" => "test"})).status
      fixture(dir, 'puts %q({"type":"text","part":{"text":"partial"}})')
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true)
      assert_equal "unknown", adapter.execute(request(dir, {"prompt" => "test"})).status
      fixture(dir, 'STDERR.write("failed"); exit 2')
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true)
      assert_equal "failure", adapter.execute(request(dir, {"prompt" => "test"})).status
    end
  end

  def test_opencode_error_event_overrides_successful_exit
    in_tmp do |dir|
      executable = fixture(dir, <<~RUBY)
        puts %q({"type":"step_finish","part":{"tokens":{"input":1}}})
        puts %q({"type":"error","error":{"message":"fixture failure"}})
      RUBY
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true).execute(request(dir, {"prompt" => "test"}))
      assert_equal "failure", result.status
      assert_equal "error", result.error["type"]
      assert_nil result.cost
    end
  end

  def test_adapters_prefer_isolated_repository_input
    in_tmp do |dir|
      repo = File.join(dir, "repository")
      Dir.mkdir(repo)
      executable = fixture(dir, <<~RUBY)
        require "json"
        File.write("changed.txt", "local change")
        puts JSON.generate(type: "text", part: {text: Dir.pwd})
        puts JSON.generate(type: "step_finish", part: {})
      RUBY
      req = request(dir, {"prompt" => "test", "live" => true})
      req.inputs = {"repository" => repo}
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest).execute(req)
      assert_equal "success", result.status
      assert_equal repo, result.outputs["repository"]
      assert_includes result.outputs["patch"], "new file mode"
      assert_includes result.outputs["patch"], "+local change"
      assert File.file?(File.join(repo, "changed.txt"))
      refute File.exist?(File.join(dir, "changed.txt"))
      req.config = {"argv" => [RbConfig.ruby, "-e", "puts Dir.pwd"]}
      shell = AgentRuntime::Adapters::Shell.new.execute(req)
      assert_equal File.realpath(repo), shell.outputs["stdout"].strip
    end
  end

  def test_git_patch_tracks_delete_modify_binary_and_untracked_without_touching_index
    in_tmp do |dir|
      File.write(File.join(dir, "deleted.txt"), "gone\n")
      File.write(File.join(dir, "modified.txt"), "before\n")
      value, patch = AgentRuntime::Adapters::GitPatch.new(dir).capture do
        File.delete(File.join(dir, "deleted.txt"))
        File.write(File.join(dir, "modified.txt"), "after\n")
        File.binwrite(File.join(dir, "added.bin"), "\x00\x01\xff")
        :executed
      end
      assert_equal :executed, value
      assert_includes patch, "deleted file mode"
      assert_includes patch, "-before"
      assert_includes patch, "+after"
      assert_includes patch, "GIT binary patch"
      refute File.exist?(File.join(dir, ".git"))
    end
  end

  def test_permission_error_is_blocked_and_observed_model_not_requested_model
    in_tmp do |dir|
      executable = fixture(dir, <<~RUBY)
        puts %q({"type":"step_finish","part":{"modelID":"actual-model"}})
        puts %q({"type":"error","error":{"message":"Permission denied"}})
      RUBY
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true).execute(request(dir, {"prompt" => "test", "model" => "requested/model"}))
      assert_equal "blocked", result.status
      assert_equal "actual-model", result.model
      assert_equal "requested/model", result.outputs["requested_model"]
      assert_kind_of Hash, result.error
    end
  end

  def test_opencode_timeout_preserved_with_truncated_json
    in_tmp do |dir|
      executable = fixture(dir, 'STDOUT.sync = true; print "{"; sleep 4')
      result = AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable, fixture_sha256: Digest::SHA256.file(executable).hexdigest, live: true).execute(request(dir, {"prompt" => "test"}, timeout: 0.5))
      assert_equal "timeout", result.status
      assert_match "invalid OpenCode JSON", result.error["message"]
    end
  end

  def test_process_env_and_working_directory
    in_tmp do |dir|
      result = runner.call(argv: [RbConfig.ruby, "-e", 'puts Dir.pwd; puts ENV.fetch("FIXTURE_KEY"); puts STDIN.read.empty?'], cwd: dir, timeout: 2, env: {"FIXTURE_KEY" => "local"})
      assert_equal [File.realpath(dir), "local", "true"], result["stdout"].lines.map(&:strip)
    end
  end

  def test_invalid_utf8_is_sanitized
    in_tmp do |dir|
      result = runner.call(argv: [RbConfig.ruby, "-e", 'STDOUT.write([255].pack("C"))'], cwd: dir, timeout: 2)
      assert result["stdout"].valid_encoding?
      assert_equal "success", result["status"]
    end
  end

  def test_openspec_import_is_local_exclusive_and_rejects_traversal
    in_tmp do |dir|
      source = File.join(dir, "source.md")
      File.write(source, "# Local specification")
      integration = AgentRuntime::Integrations::OpenSpec.new(workspace: dir)
      imported = integration.import(source: source, name: "safe-spec")
      assert_equal "# Local specification", File.read(imported["path"])
      assert_raises(Errno::EEXIST) { integration.import(source: source, name: "safe-spec") }
      assert_raises(ArgumentError) { integration.import(source: source, name: "../escape") }
      File.symlink(dir, File.join(dir, "openspec", "specs", "symlink"))
      assert_raises(Errno::EEXIST) { integration.import(source: source, name: "symlink") }
    end
  end

  def test_openspec_inspect_validate_use_json_local_cli
    in_tmp do |dir|
      executable = fixture(dir, 'require "json"; puts JSON.generate(args: ARGV, telemetry: ENV["OPENSPEC_TELEMETRY"])')
      integration = AgentRuntime::Integrations::OpenSpec.new(workspace: dir, executable: executable)
      inspected = integration.inspect(item: "m0-runtime")
      assert_equal "success", inspected["status"]
      assert_equal "show", inspected["data"]["args"].first
      assert_equal "0", inspected["data"]["telemetry"]
      assert_includes integration.validate["data"]["args"], "--strict"
      assert_raises(ArgumentError) { integration.validate(item: "--all") }
    end
  end
end
