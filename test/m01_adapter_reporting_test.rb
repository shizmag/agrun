require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks"
require "rbconfig"
require "open3"

# All CLI fixtures are generated local Ruby programs, never the real opencode.
class M01AdapterReportingTest < Minitest::Test
  FINISH = {"type" => "step_finish", "part" => {}}.freeze

  def executable(root, body)
    path = File.join(root, "local fixture #{SecureRandom.hex(4)}")
    File.write(path, "#!#{RbConfig.ruby}\nrequire 'json'\nSTDOUT.sync = true\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def request(root, config = {}, **options)
    AgentRuntime::Request.new(run_id: "local", step_id: "edit", attempt: 1,
      workspace: root, inputs: {}, config: {"prompt" => "edit"}.merge(config),
      timeout: 3, cancellation: AgentRuntime::Cancellation.new, **options)
  end

  def cli(root, body, config = {}, **options)
    AgentRuntime::Adapters::OpenCodeCLI.new(executable: executable(root, body), live: true)
      .execute(request(root, config, **options))
  end

  def readonly(store)
    db = SQLite3::Database.new(File.join(store.root, "metadata.sqlite3"), readonly: true)
    yield db
  ensure
    db&.close
  end

  def program(retries: 2, outputs: {"answer" => "text"})
    {"schema_version" => 1, "name" => "D", "inputs" => {"seed" => "text"},
     "executors" => {"x" => {"adapter" => "local", "config" => {}}},
     "steps" => [{"id" => "edit", "executor" => "x", "inputs" => {"seed" => "seed"},
                  "outputs" => outputs, "needs" => [], "config" => {}, "timeout" => 3, "retries" => retries}],
     "outputs" => {"answer" => "edit.answer"}}
  end

  def runtime(store, &block)
    adapter = Object.new
    adapter.define_singleton_method(:execute, &block)
    AgentRuntime::Runtime.new(store: store, executors: {local: adapter})
  end

  def test_d01_opt_in_and_d02_exact_argv_environment_and_repository
    in_tmp do |root|
      repo = File.join(root, "repo")
      FileUtils.mkdir_p(repo)
      marker = File.join(root, "observed.json")
      path = executable(root, "File.write(ENV.fetch('MARKER'), JSON.generate([ARGV, Dir.pwd, ENV['VALUE']]))\nputs #{JSON.generate(FINISH).inspect}")
      adapter = AgentRuntime::Adapters::OpenCodeCLI.new(executable: path)
      [nil, "true"].each do |opt|
        result = adapter.execute(request(root, {"live" => opt}))
        assert_equal "blocked", result.status
        refute File.exist?(marker)
      end
      prompt = "--help ; touch #{File.join(root, "SHELL")} $(false)"
      result = adapter.execute(request(root, {"live" => true, "prompt" => prompt,
        "model" => "requested/model", "agent" => "builder", "session_id" => "session",
        "env" => {"MARKER" => marker, "VALUE" => "literal;$HOME"}}, inputs: {"repository" => repo}))
      assert_equal "success", result.status
      assert_equal [["run", "--format", "json", "--standalone", "--model", "requested/model", "--agent", "builder", "--session", "session", "--", prompt], File.realpath(repo), "literal;$HOME"], JSON.parse(File.read(marker))
      refute File.exist?(File.join(root, "SHELL"))
    end
  end

  def test_d02_d03_missing_executable_and_invalid_arguments
    in_tmp do |root|
      runner = AgentRuntime::Adapters::ProcessRunner.new
      assert_equal "failure", runner.call(argv: [File.join(root, "absent")], cwd: root, timeout: 1)["status"]
      [[], "ruby", [nil], ["a\0b"]].each do |argv|
        assert_raises(ArgumentError) { runner.call(argv: argv, cwd: root, timeout: 1) }
      end
      [0, -1, Float::INFINITY, Float::NAN].each do |timeout|
        assert_raises(ArgumentError) { runner.call(argv: [RbConfig.ruby], cwd: root, timeout: timeout) }
      end
      assert_raises(ArgumentError) { runner.call(argv: [RbConfig.ruby], cwd: root, timeout: 1, env: {a: 1}) }
      [nil, "", 1].each do |prompt|
        result = cli(root, "raise 'must not start'", {"prompt" => prompt})
        assert_equal "failure", result.status
        assert_equal "configuration", result.error["type"]
      end
    end
  end

  def test_d04_d05_invalid_mixed_and_incomplete_streams_never_succeed
    in_tmp do |root|
      ["", "[]\n", "null\n", "{", "log line\n#{JSON.generate(FINISH)}\n",
        "#{JSON.generate(FINISH)}\n{", JSON.generate({"type" => "text", "part" => {"text" => "partial"}})].each do |stream|
        result = cli(root, "STDOUT.write(#{stream.inspect})")
        assert_equal "unknown", result.status, stream.inspect
      end
      result = cli(root, "puts #{JSON.generate(FINISH).inspect}; STDOUT.write('{' + 'x' * 1_100_000)")
      assert_equal "unknown", result.status
      assert_equal 1_048_576, result.logs["stdout"].bytesize
    end
  end

  def test_d04_d10_present_and_absent_observed_metrics
    in_tmp do |root|
      events = [{"type" => "text", "sessionID" => "observed-session", "part" => {"text" => "hello", "modelID" => "observed/model"}},
        {"type" => "step_finish", "part" => {"tokens" => {"input" => 7}, "cost" => 0.25}},
        {"type" => "step_finish", "part" => {"tokens" => {"output" => 3}, "cost" => 0.5}}]
      stream = "\n" + events.map { |event| JSON.generate(event) }.join("\n") + "\n"
      result = cli(root, "STDOUT.write(#{stream.inspect}); STDERR.write('diagnostic')", {"model" => "requested/model"})
      assert_equal "success", result.status
      assert_equal "hello", result.outputs["text"]
      assert_equal "observed/model", result.model
      assert_equal "requested/model", result.outputs["requested_model"]
      assert_equal "observed-session", result.session_id
      assert_equal({"steps" => [{"input" => 7}, {"output" => 3}]}, result.usage)
      assert_equal 0.75, result.cost
      assert_equal({"stdout" => stream, "stderr" => "diagnostic"}, result.logs)
      absent = cli(root, "puts #{JSON.generate(FINISH).inspect}", {"model" => "requested/model"})
      [absent.model, absent.usage, absent.cost, absent.session_id].each { |value| assert_nil value }
    end
  end

  def test_d05_exact_capture_limit_is_not_truncated
    assert_capture_boundary("stdout", AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT, false)
  end

  def test_d05_capture_limit_plus_one_is_truncated
    assert_capture_boundary("stdout", AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT + 1, true)
  end

  def test_d05_exact_stderr_capture_limit_is_not_truncated
    assert_capture_boundary("stderr", AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT, false)
  end

  def test_d05_stderr_capture_limit_plus_one_is_truncated
    assert_capture_boundary("stderr", AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT + 1, true)
  end

  def assert_capture_boundary(stream, size, truncated)
    in_tmp do |root|
      result = AgentRuntime::Adapters::ProcessRunner.new.call(
        argv: [RbConfig.ruby, "-e", "#{(stream == "stdout") ? "STDOUT" : "STDERR"}.write('x' * #{size})"],
        cwd: root, timeout: 3
      )
      assert_equal "success", result["status"]
      assert_equal [size, AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT].min, result[stream].bytesize
      assert_equal truncated, result["truncated"], stream
      assert_equal truncated, result["#{stream}_truncated"], stream
      assert_equal false, result["#{(stream == "stdout") ? "stderr" : "stdout"}_truncated"]
    end
  end

  def test_d05_complete_retained_event_cannot_authorize_success_after_truncation
    in_tmp do |root|
      finish = JSON.generate(FINISH) + "\n"
      limit = AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT
      prefix = finish + " " * (limit - finish.bytesize)
      result = cli(root, "STDOUT.write(#{finish.inspect}); STDOUT.write(' ' * #{limit - finish.bytesize}); STDOUT.write('x')")
      assert_equal prefix, result.logs["stdout"]
      assert_equal "unknown", result.status
    end
  end

  def test_d05_exact_limit_complete_event_remains_successful
    in_tmp do |root|
      finish = JSON.generate(FINISH) + "\n"
      limit = AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT
      result = cli(root, "STDOUT.write(#{finish.inspect}); STDOUT.write(' ' * #{limit - finish.bytesize})")
      assert_equal limit, result.logs["stdout"].bytesize
      assert_equal "success", result.status
    end
  end

  def test_d05_stderr_truncation_cannot_authorize_success
    in_tmp do |root|
      result = cli(root, "puts #{JSON.generate(FINISH).inspect}; STDERR.write('x' * #{AgentRuntime::Adapters::ProcessRunner::CAPTURE_LIMIT + 1})")
      assert_equal "unknown", result.status
    end
  end

  def test_d05_truncation_preserves_interrupted_statuses
    in_tmp do |root|
      %w[timeout cancelled].each do |status|
        runner = Object.new
        runner.define_singleton_method(:call) do |**_|
          {"status" => status, "stdout" => JSON.generate(FINISH), "stderr" => "", "truncated" => true}
        end
        result = AgentRuntime::Adapters::OpenCodeCLI.new(runner: runner, live: true).execute(request(root))
        assert_equal status, result.status
      end
    end
  end

  def test_d06_nonzero_generic_and_permission_events
    in_tmp do |root|
      [["puts #{JSON.generate(FINISH).inspect}; exit 7", "failure"],
        ["puts '{'; exit 7", "failure"],
        ["puts JSON.generate(type: 'error', message: 'broken')", "failure"],
        ["puts JSON.generate(type: 'error', message: 'permission denied')", "blocked"]].each do |body, expected|
        result = cli(root, body)
        assert_equal expected, result.status
        refute_equal "transport", result.error["classification"]
      end
    end
  end

  def test_d07_multifile_binary_deletion_patch_applies_to_independent_copy
    in_tmp do |root|
      repo = File.join(root, "repo")
      copy = File.join(root, "copy")
      FileUtils.mkdir_p(repo)
      {"a" => "before a\n", "b" => "before b\n", "deleted" => "old\n"}.each { |name, bytes| File.binwrite(File.join(repo, name), bytes) }
      FileUtils.cp_r(repo, copy)
      body = "File.write('a', 'after a'); File.write('b', 'after b'); File.unlink('deleted'); File.write('new', 'new'); File.binwrite('binary', [0, 255, 1].pack('C*')); puts #{JSON.generate(FINISH).inspect}"
      result = cli(root, body, {}, inputs: {"repository" => repo})
      assert_equal "success", result.status
      _, stderr, status = Open3.capture3("git", "apply", "--binary", "-", chdir: copy, stdin_data: result.outputs["patch"])
      assert status.success?, stderr
      expected = {"a" => "after a".b, "b" => "after b".b, "new" => "new".b, "binary" => [0, 255, 1].pack("C*")}
      [repo, copy].each do |directory|
        assert_equal expected.keys.sort, Dir.children(directory).reject { |name| name == ".git" }.sort
        expected.each { |name, bytes| assert_equal bytes, File.binread(File.join(directory, name)) }
        refute File.exist?(File.join(directory, "deleted"))
      end
      assert_equal AgentRuntime::Store.manifest(repo), AgentRuntime::Store.manifest(copy)
      assert_empty cli(root, "puts #{JSON.generate(FINISH).inspect}", {}, inputs: {"repository" => repo}).outputs["patch"]
    end
  end

  def process_alive?(pid)
    _, _, status = Open3.capture3("ps", "-p", pid.to_s, "-o", "stat=")
    return false unless status.success?
    state, = Open3.capture2("ps", "-p", pid.to_s, "-o", "stat=")
    !state.strip.empty? && !state.start_with?("Z")
  end

  def wait_until
    Timeout.timeout(5) { sleep(0.01) until yield }
  end

  def assert_descendant_cleanup(expected, mode = :resistant)
    in_tmp do |root|
      marker = File.join(root, expected)
      leader_trap = (mode == :resistant) ? "trap('TERM') {}" : "trap('TERM') { exit! 0 }"
      child_trap = (mode == :responsive) ? "trap('TERM') { exit! 0 }" : "trap('TERM') {}"
      leader_end = (mode == :exited_leader) ? "exit! 0" : "loop { sleep 1 }"
      path = executable(root, "#{leader_trap}; child = fork { #{child_trap}; loop { sleep 1 } }; File.write(#{marker.inspect}, JSON.generate([Process.pid, child])); STDOUT.sync = true; puts 'partial'; #{leader_end}")
      token = AgentRuntime::Cancellation.new
      pids = []
      worker = Thread.new { AgentRuntime::Adapters::ProcessRunner.new.call(argv: [path], cwd: root, timeout: (expected == "timeout") ? 5 : 15, cancellation: token) }
      begin
        Timeout.timeout(15) { sleep(0.01) until File.exist?(marker) }
        pids = JSON.parse(File.read(marker))
        token.cancel! if expected == "cancelled"
        result = Timeout.timeout(15) { worker.value }
        assert_equal expected, result["status"]
        assert_includes result["stdout"], "partial"
        wait_until { pids.none? { |pid| process_alive?(pid) } }
        pids.each { |pid| refute process_alive?(pid), "live fixture descendant #{pid}" }
        assert_raises(Errno::ECHILD) { Process.waitpid(pids.first, Process::WNOHANG) }
      ensure
        pids.each do |pid|
          Process.kill("KILL", pid) if process_alive?(pid)
        rescue Errno::ESRCH
          nil
        end
        worker.join(5)
      end
    end
  end

  def test_d08_timeout_kills_term_resistant_descendants
    assert_descendant_cleanup("timeout")
  end

  def test_d09_active_cancel_kills_term_resistant_descendants
    assert_descendant_cleanup("cancelled")
  end

  def test_d08_term_responsive_group_timeout
    assert_descendant_cleanup("timeout", :responsive)
  end

  def test_d09_term_responsive_group_cancel
    assert_descendant_cleanup("cancelled", :responsive)
  end

  def test_d08_exited_leader_resistant_descendant_timeout
    assert_descendant_cleanup("timeout", :exited_leader)
  end

  def test_d09_exited_leader_resistant_descendant_cancel
    assert_descendant_cleanup("cancelled", :exited_leader)
  end

  def test_d08_responsive_leader_resistant_descendant_timeout
    assert_descendant_cleanup("timeout", :responsive_leader)
  end

  def test_d09_responsive_leader_resistant_descendant_cancel
    assert_descendant_cleanup("cancelled", :responsive_leader)
  end

  def test_d09_pre_cancel_prevents_spawn_and_next_invocation_succeeds
    in_tmp do |root|
      token = AgentRuntime::Cancellation.new
      token.cancel!
      marker = File.join(root, "pre-cancel")
      path = executable(root, "File.write(#{marker.inspect}, 'started')")
      assert_equal "cancelled", AgentRuntime::Adapters::ProcessRunner.new.call(argv: [path], cwd: root, timeout: 1, cancellation: token)["status"]
      refute File.exist?(marker)
      assert_equal "success", AgentRuntime::Adapters::ProcessRunner.new.call(argv: [RbConfig.ruby, "-e", "puts 'ok'"], cwd: root, timeout: 1)["status"]
    end
  end

  def test_d06_timeout_status_prevails_permission_event
    in_tmp do |root|
      result = cli(root, "puts JSON.generate(type: 'error', message: 'permission denied'); sleep 5", {}, timeout: 0.6)
      assert_equal "timeout", result.status
    end
  end

  def test_d06_cancelled_status_prevails_permission_event
    in_tmp do |root|
      marker = File.join(root, "ready")
      token = AgentRuntime::Cancellation.new
      worker = Thread.new do
        cli(root, "puts JSON.generate(type: 'error', message: 'permission denied'); File.write(#{marker.inspect}, 'ready'); sleep 5", {}, cancellation: token)
      end
      begin
        wait_until { File.exist?(marker) }
        token.cancel!
        assert_equal "cancelled", Timeout.timeout(5) { worker.value }.status
      ensure
        token.cancel!
        worker.join(5)
      end
    end
  end

  def test_d11_d12_transport_retry_persists_terminal_attempts_logs_and_lineage
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      calls = []
      runner = runtime(store) do |req|
        calls << req.attempt
        AgentRuntime::Result.new(status: (req.attempt == 1) ? "failure" : "success", outputs: {"answer" => "accepted"},
          error: (req.attempt == 1) ? {"classification" => "transport"} : nil, retry_safe: true, logs: "attempt #{req.attempt}")
      end
      report = runner.run(program, inputs: {seed: "original"})
      assert_equal [1, 2], calls
      assert_equal "success", report["status"]
      assert_equal report, AgentRuntime::Store.new(root).report(report["run_id"])
      readonly(store) do |db|
        rows = db.execute("SELECT attempt, data FROM attempts WHERE run_id=? ORDER BY attempt", [report["run_id"]])
        assert_equal [1, 2], rows.map(&:first)
        assert_equal %w[failure success], rows.map { |row| JSON.parse(row.last)["status"] }
        rows.each { |row| assert_equal "attempt #{row.first}", store.value(JSON.parse(row.last).fetch("log")) }
        accepted = db.execute("SELECT data FROM artifacts").map { |row| JSON.parse(row.first) }.select { |artifact| artifact["step_id"] == "edit" && !artifact["inputs"].empty? }
        assert_equal 1, accepted.size
        assert_equal 2, accepted.first["attempt"]
        assert_equal "accepted", store.value(accepted.first)
        input = db.get_first_value("SELECT data FROM artifacts WHERE id=?", [accepted.first["inputs"].first])
        assert_equal "original", store.value(JSON.parse(input))
        assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      end
    end
  end

  def test_d11_no_retry_for_semantic_or_interrupted_results_and_bounded_transport
    in_tmp do |root|
      [%w[failure semantic], %w[failure configuration], %w[unknown invalid_output], %w[blocked permission], %w[timeout timeout], %w[cancelled cancelled], %w[failure transport]].each_with_index do |(status, classification), index|
        store = AgentRuntime::Store.new(File.join(root, index.to_s))
        calls = 0
        runner = runtime(store) do |_req|
          calls += 1
          AgentRuntime::Result.new(status: status, outputs: {"answer" => "partial"}, error: {"classification" => classification}, retry_safe: true, logs: "partial log")
        end
        report = runner.run(program, inputs: {seed: "original"})
        assert_equal (classification == "transport") ? 3 : 1, calls
        refute_equal "success", report["status"]
        assert_empty report["outputs"]
        readonly(store) do |db|
          assert_equal calls, db.get_first_value("SELECT COUNT(*) FROM attempts")
          assert_equal 0, db.get_first_value("SELECT COUNT(*) FROM attempts WHERE json_extract(data, '$.status')='running'")
        end
      end
    end
  end

  def test_d13_partial_output_validation_never_accepts_artifacts
    in_tmp do |root|
      [{"answer" => "valid"}, {"answer" => "valid", "number" => "wrong"}].each_with_index do |outputs, index|
        store = AgentRuntime::Store.new(File.join(root, index.to_s))
        report = runtime(store) { |_req| AgentRuntime::Result.new(status: "success", outputs: outputs) }
          .run(program(outputs: {"answer" => "text", "number" => "integer"}), inputs: {seed: "input"})
        assert_equal "failure", report["status"]
        assert_equal "output_validation", report.dig("steps", "edit", "attempts", 0, "error", "classification")
        assert_empty report["outputs"]
        assert_empty report.dig("steps", "edit", "outputs")
        assert_equal 1, report.dig("steps", "edit", "attempts").size
      end
    end
  end

  def test_d18_existing_upserts_do_not_duplicate_keys_or_collapse_provenance
    in_tmp do |root|
      store = AgentRuntime::Store.new(root)
      %w[r1 r2].each do |id|
        store.save_report({"run_id" => id, "status" => "running"})
        store.save_report({"run_id" => id, "status" => "failure"})
        [1, 2].each do |attempt|
          store.save_attempt(id, "edit", attempt, {"status" => "running"})
          store.save_attempt(id, "edit", attempt, {"status" => "cancelled"})
        end
      end
      a, b = [1, 2].map { |attempt| store.put(type: "text", value: "same", run_id: "r1", step_id: "edit", attempt: attempt) }
      refute_equal a["id"], b["id"]
      assert_equal a["path"], b["path"]
      readonly(store) do |db|
        assert_equal 2, db.get_first_value("SELECT COUNT(*) FROM runs")
        assert_equal 4, db.get_first_value("SELECT COUNT(*) FROM attempts")
        assert_equal ["cancelled"], db.execute("SELECT DISTINCT json_extract(data, '$.status') FROM attempts").flatten
        assert_equal 2, db.get_first_value("SELECT COUNT(*) FROM artifacts")
        assert_equal "ok", db.get_first_value("PRAGMA integrity_check")
      end
    end
  end

  def benchmark_setup(root, evaluator: nil)
    store = AgentRuntime::Store.new(File.join(root, "store"))
    task = AgentRuntime::Benchmarks::Fixture.demo(root: File.join(root, "fixture"))
    runner = AgentRuntime::Benchmarks::Runner.new(store: store, root: File.join(root, "runs"), evaluator: evaluator)
    [store, task, runner]
  end

  def assert_report_files(root, store, report)
    directory = File.join(root, "runs", report.fetch("run_id"))
    json = JSON.parse(File.read(File.join(directory, "result.json")))
    # The report contract writes fully quoted fields; scan quoted cells so commas,
    # doubled quotes and embedded newlines are not interpreted as separators.
    cells = File.read(File.join(directory, "result.csv")).scan(/"((?:[^"]|"")*)"/m).flatten.map { |cell| cell.gsub('""', '"') }
    headers = cells.shift(8)
    csv = cells.each_slice(headers.size).map { |row| headers.zip(row).to_h }
    assert_equal report, json
    assert_equal report, AgentRuntime::Store.new(store.root).report(report["run_id"])
    assert_equal 1, csv.size
    %w[run_id task_id status model duration].each do |key|
      assert_equal report[key].to_s, csv.first[key], key
    end
    assert_equal report.dig("solution", "cost").to_s, csv.first["cost"]
    assert_equal report.dig("evaluation", "verdict"), csv.first["verdict"]
    assert_equal report.dig("evaluation", "execution_status"), csv.first["execution_status"]
  end

  def test_d15_d16_good_bad_and_interrupted_reports_keep_execution_verdict_separate
    in_tmp do |root|
      store, task, runner = benchmark_setup(root)
      [true, false].each do |good|
        report = runner.run(task: task, solver: AgentRuntime::Benchmarks::Solvers::Fake.new(good: good), model: "requested/model")
        assert_equal "success", report.dig("solution", "status")
        assert_equal good ? "pass" : "fail", report.dig("evaluation", "verdict")
        assert_report_files(root, store, report)
        report["artifact_refs"].each_value { |artifact| store.value(artifact) }
      end
      %w[blocked failure unknown timeout cancelled].each do |status|
        solver = Object.new
        solver.define_singleton_method(:solve) { |**_| {"status" => status, "error" => {"message" => "local fixture"}} }
        report = runner.run(task: task, solver: solver)
        assert_equal status, report["status"]
        assert_equal "not_started", report.dig("evaluation", "execution_status")
        assert_equal "not_evaluated", report.dig("evaluation", "verdict")
        assert_nil report["cost"]
        assert_nil report["observed_model"]
        assert_nil report.dig("solution", "usage")
        assert_report_files(root, store, report)
      end
    end
  end

  def test_d17_matrix_retains_eight_unique_submissions_without_filtering
    in_tmp do |root|
      store, task, runner = benchmark_setup(root)
      interrupted = Object.new
      interrupted.define_singleton_method(:solve) { |**_| {"status" => "cancelled"} }
      reports = runner.matrix(tasks: [task], solvers: {"good" => AgentRuntime::Benchmarks::Solvers::Fake.new, "cancelled" => interrupted}, models: [nil, "requested/model"], repetitions: 2)
      assert_equal 8, reports.size
      assert_equal 8, reports.map { |report| report["run_id"] }.uniq.size
      assert_equal({"success" => 4, "cancelled" => 4}, reports.map { |report| report["status"] }.tally)
      assert_equal({"pass" => 4, "not_evaluated" => 4}, reports.map { |report| report.dig("evaluation", "verdict") }.tally)
      assert_equal 8, Dir.glob(File.join(root, "runs", "*", "result.json")).size
      assert_equal 8, Dir.glob(File.join(root, "runs", "*", "result.csv")).size
      readonly(store) { |db| assert_equal 8, db.get_first_value("SELECT COUNT(*) FROM runs") }
      reports.each { |report| assert_report_files(root, store, report) }
    end
  end

  def test_d19_solver_exception_is_persisted_as_not_evaluated
    in_tmp do |root|
      store, task, runner = benchmark_setup(root)
      solver = Object.new
      solver.define_singleton_method(:solve) { |**_| raise "fixture solver failed after partial work" }
      report = runner.run(task: task, solver: solver)
      assert_equal "failure", report["status"]
      assert_equal "error", report.dig("evaluation", "execution_status")
      assert_equal "not_evaluated", report.dig("evaluation", "verdict")
      assert_report_files(root, store, report)
    end
  end

  def test_d14_missing_and_invalid_patch_never_become_runtime_outputs
    in_tmp do |root|
      [{}, {"answer" => nil}, {"answer" => 7}].each_with_index do |outputs, index|
        store = AgentRuntime::Store.new(File.join(root, index.to_s))
        report = runtime(store) { |_req| AgentRuntime::Result.new(status: "success", outputs: outputs) }
          .run(program(outputs: {"answer" => "patch"}), inputs: {seed: "input"})
        assert_equal "failure", report["status"]
        assert_empty report["outputs"]
        assert_equal "output_validation", report.dig("steps", "edit", "attempts", 0, "error", "classification")
      end
    end
  end

  def test_d19_evaluator_exception_preserves_successful_solver_status
    in_tmp do |root|
      evaluator = Object.new
      evaluator.define_singleton_method(:evaluate) { |**_| raise "fixture evaluator failed" }
      store, task, runner = benchmark_setup(root, evaluator: evaluator)
      report = runner.run(task: task, solver: AgentRuntime::Benchmarks::Solvers::Fake.new)
      assert_equal "success", report["status"]
      assert_equal "success", report.fetch("solution").fetch("status")
      assert_equal "error", report.dig("evaluation", "execution_status")
      assert_equal "not_evaluated", report.dig("evaluation", "verdict")
      assert_report_files(root, store, report)
    end
  end
end
