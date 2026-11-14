require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "timeout"
require "rbconfig"
require "sqlite3"
require_relative "../../lib/agent_runtime"
require_relative "../../lib/agent_runtime/benchmarks"
require_relative "../../lib/agent_runtime/adapters/process_runner"

# Test-owned inputs and expectations. No production fixture or verdict classifier
# is used to calculate an expected result.
module M01Harness
  GOOD = "def clamp(v, lo, hi)\n  [[v, lo].max, hi].min\nend\n"
  WRONG = "def clamp(v, lo, hi)\n  v\nend\n"
  PROCEDURE = <<~RUBY
    require "json"
    load File.join(ENV.fetch("TARGET_REPOSITORY"), "clamp.rb")
    cases = [[5, 0, 10, 5], [-1, 0, 10, 0], [11, 0, 10, 10], [-8, -5, -2, -5], [0, 0, 10, 0]]
    ok = cases.all? { |v, lo, hi, expected| clamp(v, lo, hi) == expected }
    puts "AGRU_VERDICT=" + JSON.generate({"verdict" => ok ? "pass" : "fail"})
    exit(ok ? 0 : 1)
  RUBY

  ACCEPTANCE = {
    "AC01.good" => ["completed", "pass"],
    "AC02.wrong" => ["completed", "fail"],
    "AC03.repository-edited" => ["rejected", "historical"],
    "AC03.same-bytes-generation" => ["rejected", "historical"],
    "AC03.artifact-object-tampered" => ["rejected", "historical"],
    "AC03.artifact-tree-tampered" => ["rejected", "historical"],
    "AC04.spec-edited" => ["rejected", "historical"],
    "AC04.instruction-edited" => ["rejected", "historical"],
    "AC04.public-test-edited" => ["rejected", "historical"],
    "AC04.procedure-edited" => ["rejected", "historical"],
    "AC04.revision-edited" => ["rejected", "historical"],
    "AC04.base-commit-edited" => ["rejected", "historical"],
    "AC04.environment-edited" => ["rejected", "historical"],
    "AC04.timeout-edited" => ["rejected", "historical"],
    "AC05.protocol-error" => ["error", "not_evaluated"],
    "AC05.evaluator-timeout" => ["timeout", "not_evaluated"],
    "AC05.spawn-error" => ["error", "not_evaluated"],
    "AC05.evaluator-exception" => ["error", "not_evaluated"],
    "AC06.parallel" => ["isolated", "pass/fail"],
    "AC07.cooperative-interruption" => ["cancelled", "not_evaluated"]
  }.freeze

  CONFORMANCE = {
    "HC01.valid-pass" => ["completed", "pass"],
    "HC02.valid-fail" => ["completed", "fail"],
    "HC03.absent-marker" => ["error", "not_evaluated"],
    "HC04.malformed-marker" => ["error", "not_evaluated"],
    "HC05.exit-zero-fail" => ["error", "not_evaluated"],
    "HC05.exit-one-pass" => ["error", "not_evaluated"],
    "HC06.abnormal-exit" => ["error", "not_evaluated"],
    "HC07.operational-timeout" => ["timeout", "not_evaluated"],
    "HC08.operational-cancel" => ["cancelled", "not_evaluated"],
    "HC09.inferred-dataflow" => ["success", "ordered"],
    "HC10.explicit-dependency" => ["success", "ordered"],
    "HC10.failed-dependency" => ["failure", "gated"],
    "HC11.retry-accounting" => ["success", "1,2"],
    "HC11.exhausted-retry" => ["failure", "1,2"],
    "HC11.unknown-no-retry" => ["unknown", "1"],
    "HC12.isolation-and-persistence" => ["isolated", "pass/fail"]
  }.freeze

  class Mismatch < StandardError; end

  def self.canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  # Independent reference for Store's documented repository representation.
  def self.repository_digest(path)
    rows = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |file|
      relative = file.delete_prefix("#{path}/")
      next if relative == "." || relative.split("/").include?(".git") || File.directory?(file)
      raise Mismatch, "unexpected fixture symlink" if File.symlink?(file)
      {"path" => relative, "executable" => File.executable?(file), "content" => [File.binread(file)].pack("m0")}
    end
    Digest::SHA256.hexdigest(JSON.generate(canonical(rows)))
  end

  class LiteralSolver
    attr_reader :workspace

    def initialize(source, barrier: nil)
      @source, @barrier = source, barrier
    end

    def solve(task:, model:, budget:, workspace:)
      raise Mismatch, "hidden procedure leaked to solver" unless task.hidden_test.nil?
      raise Mismatch, "hidden procedure in solver workspace" if Dir.glob("#{workspace}/**/*").any? { |p| File.file?(p) && File.binread(p).include?("AGRU_VERDICT=") }
      @workspace = workspace
      @barrier&.call
      repository = File.join(workspace, "submission")
      FileUtils.mkdir_p(repository)
      File.binwrite(File.join(repository, "clamp.rb"), @source)
      {"status" => "success", "repository" => repository}
    end
  end

  class Case
    attr_reader :result

    def initialize(id, root)
      @id, @root = id, root
      @expected = ACCEPTANCE.merge(CONFORMANCE).fetch(id)
      @result = {"case_id" => id, "expected" => {"status" => @expected[0], "verdict" => @expected[1]},
                 "actual" => {}, "match" => false, "error" => nil, "artifact" => {}, "run" => {}, "attempts" => [],
                 "evidence_paths" => {"root" => root}}
    end

    def check(condition, message)
      raise Mismatch, message unless condition
    end

    def setup
      FileUtils.mkdir_p(@root)
      @store_root = File.join(@root, "store")
      @store = AgentRuntime::Store.new(@store_root)
      @repository = File.join(@root, "source")
      FileUtils.mkdir_p(@repository)
      File.write(File.join(@repository, "clamp.rb"), GOOD)
      @public = File.join(@root, "public.rb")
      File.write(@public, "raise unless clamp(5, 0, 10) == 5\n")
      @hidden = File.join(@root, "hidden.rb")
      File.write(@hidden, PROCEDURE)
      @task = AgentRuntime::Benchmarks::Task.new(id: "m01/clamp", instruction: "Clamp to inclusive bounds.",
        repository: @repository, base_commit: "a" * 40, dataset_revision: "fixture-v1", spec: {"bounds" => "inclusive"},
        hidden_test: @hidden, dataset: "m01", public_tests: [@public], limits: {}, metadata: {})
      @evaluator = AgentRuntime::Evaluation::Evaluator.new(store: @store)
    end

    def execute
      setup
      if @id.start_with?("AC03.", "AC04.")
        stale_evidence
      elsif @id == "AC06.parallel" || @id == "HC12.isolation-and-persistence"
        parallel
      elsif @id == "AC07.cooperative-interruption" || @id == "HC08.operational-cancel"
        interruption
      elsif @id.start_with?("HC09.", "HC10.", "HC11.")
        runtime_case
      else
        evaluation_case
      end
      check(@result["actual"] == @result["expected"], "expected #{@result["expected"].inspect}, got #{@result["actual"].inspect}")
      @result["match"] = true
      @result
    rescue Mismatch => error
      @result["mismatch"] = error.message
      @result
    rescue => error
      @result["error"] = {"class" => error.class.name, "message" => error.message}
      @result
    end

    def observe(status, verdict)
      @result["actual"] = {"status" => status, "verdict" => verdict}
    end

    def inspect_benchmark(report)
      run_id = report.fetch("run_id")
      @result["run"]["benchmark_run_id"] = run_id
      directory = File.join(@root, "runs", run_id)
      persisted = AgentRuntime::Store.new(@store_root).report(run_id)
      disk = JSON.parse(File.read(File.join(directory, "result.json")))
      check(persisted == report && disk == persisted, "returned/disk/reopened report mismatch")
      # Runner emits a fully quoted, single-line-per-record CSV dialect. Fixture
      # fields contain no embedded newlines; avoid adding a csv gem dependency.
      rows = File.read(File.join(directory, "result.csv")).lines.map { |line| line.chomp.delete_suffix("\r")[1...-1].split('","', -1).map { |field| field.gsub('""', '"') } }
      csv = rows.first.zip(rows.fetch(1)).to_h
      check(csv["run_id"] == run_id && csv["execution_status"] == persisted.dig("evaluation", "execution_status") && csv["verdict"] == persisted.dig("evaluation", "verdict"), "CSV evidence mismatch")
      @result["evidence_paths"].merge!("store" => @store_root, "result_json" => File.join(directory, "result.json"))
      evaluation = persisted.fetch("evaluation")
      # Exceptions before evaluation can produce a Runner operational diagnostic,
      # not an evaluator artifact. Every actual evaluator return, including its
      # protocol/timeout/spawn failures, must retain persisted report evidence.
      unless @id == "AC05.evaluator-exception"
        check(evaluation["report_artifact"].is_a?(Hash), "required evaluation report artifact missing")
        inspect_evaluation(evaluation, run_id: run_id)
      end
      persisted
    end

    def inspect_evaluation(report, run_id: @result.fetch("run").fetch("runtime_run_id"))
      reopened = AgentRuntime::Store.new(@store_root)
      artifact = report.fetch("report_artifact")
      db = SQLite3::Database.new(File.join(@store_root, "metadata.sqlite3"))
      row = db.get_first_row("SELECT digest,data FROM artifacts WHERE id=?", [artifact.fetch("id")])
      check(!row.nil?, "report artifact ID absent from persisted metadata")
      canonical = JSON.parse(row.fetch(1))
      check(canonical == artifact && canonical.fetch("id") == artifact.fetch("id"), "report artifact canonical identity mismatch")
      check(canonical["type"] == "json", "report artifact must be JSON")
      check(canonical["run_id"] == run_id, "report artifact run mismatch")
      evaluation_id = report.fetch("evaluation_id")
      check(evaluation_id.is_a?(String) && !evaluation_id.empty?, "evaluation identity missing")
      check(canonical.fetch("metadata")["evaluation_id"] == evaluation_id, "report evaluation association mismatch")
      inputs = report.fetch("artifacts")
      check(inputs.keys.sort == %w[artifact environment procedure specification], "evaluation evidence set mismatch")
      check(canonical.fetch("inputs") == inputs.values, "report inputs do not bind all four evaluation artifacts")
      inputs.each do |name, input|
        input_row = db.get_first_row("SELECT digest,data FROM artifacts WHERE id=?", [input.fetch("id")])
        check(!input_row.nil? && JSON.parse(input_row.fetch(1)) == input, "#{name} canonical metadata mismatch")
        check(input["run_id"] == run_id && input.fetch("metadata")["evaluation_id"] == evaluation_id, "#{name} evaluation/run association mismatch")
        check(input.fetch("digest") == input_row.fetch(0) && report.fetch("bindings").fetch(name) == input_row.fetch(0), "#{name} binding differs from persisted digest")
      end
      bytes = File.binread(canonical.fetch("path"))
      independent_digest = Digest::SHA256.hexdigest(bytes)
      check(independent_digest == row.fetch(0) && independent_digest == artifact.fetch("digest"), "stored report independent digest mismatch")
      check(File.basename(canonical.fetch("path")) == independent_digest, "report object path/digest mismatch")
      check(JSON.generate(M01Harness.canonical(JSON.parse(bytes))) == bytes, "report object bytes not canonical")
      stored = reopened.value(artifact)
      check(stored == JSON.parse(bytes), "report artifact decoded value differs from persisted bytes")
      report.each do |key, value|
        next if key == "report_artifact"
        check(stored[key] == value, "persisted report #{key} differs from returned evidence")
      end
      check(stored["execution_status"] == report["execution_status"] && stored["verdict"] == report["verdict"], "stored evaluation status mismatch")
      check(stored.fetch("bindings") == report.fetch("bindings"), "stored evaluation binding mismatch")
      @result["artifact"]["evaluation_report"] = artifact.fetch("id")
      report.fetch("artifacts").each do |kind, metadata|
        @result["artifact"][kind] = metadata.fetch("id")
        value = reopened.value(metadata)
        digest = if metadata["type"] == "repository"
          M01Harness.repository_digest(value)
        elsif %w[json evaluation_report].include?(metadata["type"])
          Digest::SHA256.hexdigest(JSON.generate(M01Harness.canonical(value)))
        else
          Digest::SHA256.hexdigest(value)
        end
        check(digest == metadata["digest"], "independent #{kind} digest mismatch")
        binding = {"repository" => "artifact", "spec" => "specification"}.fetch(kind, kind)
        check(report.fetch("bindings").fetch(binding) == digest, "#{kind} binding mismatch")
      end
      stored
    ensure
      db&.close
    end

    def benchmark(source = GOOD, evaluator: @evaluator)
      runner = AgentRuntime::Benchmarks::Runner.new(store: @store, root: File.join(@root, "runs"), evaluator: evaluator)
      inspect_benchmark(runner.run(task: @task, solver: LiteralSolver.new(source), budget: {"evaluation_timeout" => 0.5}))
    end

    def evaluation_case
      source = case @id
      when "AC02.wrong", "HC02.valid-fail"
        WRONG
      else
        GOOD
      end
      case @id
      when "AC05.protocol-error", "HC03.absent-marker" then File.write(@hidden, "exit 0\n")
      when "HC04.malformed-marker" then File.write(@hidden, "puts 'AGRU_VERDICT={'\n")
      when "HC05.exit-zero-fail" then File.write(@hidden, "puts 'AGRU_VERDICT={\"verdict\":\"fail\"}'\n")
      when "HC05.exit-one-pass" then File.write(@hidden, "puts 'AGRU_VERDICT={\"verdict\":\"pass\"}'\nexit 1\n")
      when "HC06.abnormal-exit" then File.write(@hidden, "puts 'AGRU_VERDICT={\"verdict\":\"fail\"}'\nexit 2\n")
      when "AC05.evaluator-timeout", "HC07.operational-timeout"
        File.write(@hidden, "File.write(#{File.join(@root, "started").inspect}, Process.pid.to_s)\nsleep 30\n")
      when "AC05.spawn-error"
        process = Object.new
        process.define_singleton_method(:call) { |**_args| {"status" => "failure", "exit_code" => nil, "stdout" => "", "stderr" => "fixture spawn failure"} }
        @evaluator = AgentRuntime::Evaluation::Evaluator.new(store: @store, process_runner: process)
      when "AC05.evaluator-exception"
        @evaluator = Object.new
        @evaluator.define_singleton_method(:evaluate) { |**_args| raise AgentRuntime::Error, "fixture evaluator exception" }
      end
      report = benchmark(source)
      check(report["status"] == "success" || report["solver_status"] == "success", "successful solver status lost on evaluator exception")
      evaluation = report.fetch("evaluation")
      if @id == "AC05.spawn-error"
        check(report.fetch("status") == "success" && report.fetch("solution").fetch("status") == "success", "successful solver status lost on evaluator spawn failure")
        check(evaluation.fetch("execution").fetch("status") == "failure", "evaluator spawn execution failure lost")
      end
      observe(evaluation["execution_status"], evaluation["verdict"])
      if evaluation["artifacts"]
        repo = @store.value(evaluation.fetch("artifacts").fetch("artifact"))
        check(File.binread(File.join(repo, "clamp.rb")) == source, "stored submitted bytes incorrect")
      end
      if @id.include?("timeout")
        check(File.exist?(File.join(@root, "started")), "timeout procedure never started")
        dead_process(Integer(File.read(File.join(@root, "started"))))
      end
    end

    def require_evidence_api
      check(@evaluator.respond_to?(:verify!), "newly specified API unavailable: Evaluator#verify!")
      check(@store.respond_to?(:artifact), "newly specified API unavailable: Store#artifact")
    end

    def stale_evidence
      old = ENV["AGRU_M01_EVIDENCE_SENTINEL"]
      # Establish a genuine producing Runtime attempt; a duplicate identity comes
      # from a second Store generation, not from editing metadata in the oracle.
      producer = runtime_program([step("produce", outputs: {"repository" => "repository"})], {"repository" => "produce.repository"})
      adapter = Object.new
      adapter.define_singleton_method(:execute) { |_request| AgentRuntime::Result.new(status: "success", outputs: {"repository" => @path}) }
      adapter.instance_variable_set(:@path, @repository)
      produced = AgentRuntime::Runtime.new(store: @store, executors: {"local" => adapter}).run(producer)
      inspect_runtime(produced)
      generation = produced.fetch("outputs").fetch("repository")
      require_evidence_api
      canonical = @store.artifact(generation.fetch("id"))
      check(canonical == generation, "canonical artifact metadata differs from actual producer output")
      report = @evaluator.evaluate(task: @task, repository: @repository, run_id: produced.fetch("run_id"), timeout: 2, generation: canonical)
      check(report["execution_status"] == "completed" && report["verdict"] == "pass", "initial real grading failed")
      original = inspect_evaluation(report)
      history = JSON.generate(report)
      verify = {report: report, task: @task, repository: @repository, run_id: produced.fetch("run_id"), timeout: 2, generation: canonical}
      accepted = @evaluator.verify!(**verify)
      check(accepted == report, "unchanged evidence not accepted")
      check(report["identity_mode"] == "submitted", "submitted identity mode missing")
      check(!report["evaluation_id"].to_s.empty?, "evaluation identity missing")
      case @id
      when "AC03.repository-edited" then File.write(File.join(@repository, "clamp.rb"), WRONG)
      when "AC03.same-bytes-generation"
        other = @store.put(type: "repository", value: @repository, run_id: produced.fetch("run_id"), step_id: "other", attempt: 1)
        check(other["digest"] == canonical["digest"] && other["id"] != canonical["id"], "fixture did not create distinct same-content generation")
        verify[:generation] = @store.artifact(other.fetch("id"))
      when "AC03.artifact-object-tampered"
        path = File.join(@store_root, "objects", canonical.fetch("digest"))
        File.chmod(0o644, path)
        File.write(path, "tampered")
      when "AC03.artifact-tree-tampered"
        path = File.join(@store.value(canonical), "clamp.rb")
        File.chmod(0o644, path)
        File.write(path, WRONG)
      when "AC04.spec-edited" then @task.spec = {"bounds" => "changed"}
      when "AC04.instruction-edited" then @task.instruction = "A different instruction."
      when "AC04.public-test-edited" then File.write(@public, "raise 'different public check'\n")
      when "AC04.procedure-edited" then File.write(@hidden, "puts 'AGRU_VERDICT={\"verdict\":\"fail\"}'\nexit 1\n")
      when "AC04.revision-edited" then @task.dataset_revision = "fixture-v2"
      when "AC04.base-commit-edited" then @task.base_commit = "b" * 40
      when "AC04.environment-edited"
        ENV["AGRU_M01_EVIDENCE_SENTINEL"] = "changed-#{old}"
      when "AC04.timeout-edited" then verify[:timeout] = 3
      end
      rejected = false
      begin
        @evaluator.verify!(**verify)
      rescue AgentRuntime::Error
        rejected = true
      end
      check(rejected, "stale evidence was accepted")
      check(JSON.generate(report) == history, "verification mutated historical report in place")
      # Store#value validates transitive provenance and must reject a report with
      # corrupted inputs. Inspect historical bytes/metadata directly instead of
      # requiring corrupt evidence to remain loadable through that public API.
      historical = report.fetch("report_artifact")
      bytes = File.binread(historical.fetch("path"))
      check(JSON.parse(bytes) == original && Digest::SHA256.hexdigest(bytes) == historical.fetch("digest"), "persisted historical evaluation changed")
      db = SQLite3::Database.new(File.join(@store_root, "metadata.sqlite3"))
      row = db.get_first_row("SELECT digest,data FROM artifacts WHERE id=?", [historical.fetch("id")])
      check(row && row.fetch(0) == historical.fetch("digest") && JSON.parse(row.fetch(1)) == historical, "persisted historical metadata changed")
      observe("rejected", "historical")
    ensure
      db&.close
      if @id == "AC04.environment-edited"
        old.nil? ? ENV.delete("AGRU_M01_EVIDENCE_SENTINEL") : ENV["AGRU_M01_EVIDENCE_SENTINEL"] = old
      end
    end

    def parallel
      entered, release = Queue.new, Queue.new
      barrier = -> {
        entered << true
        Timeout.timeout(5) { release.pop }
      }
      solvers = [LiteralSolver.new(GOOD, barrier: barrier), LiteralSolver.new(WRONG, barrier: barrier)]
      runner = AgentRuntime::Benchmarks::Runner.new(store: @store, root: File.join(@root, "runs"))
      threads = solvers.map { |solver| Thread.new { runner.run(task: @task, solver: solver) } }
      Timeout.timeout(5) { 2.times { entered.pop } }
      2.times { release << true }
      reports = threads.map { |thread| Timeout.timeout(10) { thread.value } }
      reports.each { |report| inspect_benchmark(report) }
      check(reports.map { |r| r["run_id"] }.uniq.size == 2, "parallel run ID collision")
      check(solvers.map(&:workspace).uniq.size == 2, "parallel workspace collision")
      check(reports.map { |r| r.dig("evaluation", "verdict") } == %w[pass fail], "cross-run grading contamination")
      artifacts = reports.map { |r| r.fetch("evaluation").fetch("artifacts").fetch("artifact") }
      check(artifacts.map { |a| a["id"] }.uniq.size == 2, "parallel generation collision")
      artifacts.zip([GOOD, WRONG], reports).each do |artifact, source, report|
        check(artifact["run_id"] == report["run_id"], "cross-run artifact provenance")
        check(File.read(File.join(@store.value(artifact), "clamp.rb")) == source, "cross-run bytes")
      end
      @result["run"]["parallel_run_ids"] = reports.map { |r| r["run_id"] }
      observe("isolated", "pass/fail")
    ensure
      2.times { release << true } if release
      threads&.each { |thread| thread.join(5) || thread.kill.join }
    end

    def step(id, needs: [], inputs: {}, outputs: {"value" => "text"}, retries: 0)
      {"id" => id, "executor" => "local", "inputs" => inputs, "outputs" => outputs, "needs" => needs, "config" => {}, "timeout" => 5, "retries" => retries}
    end

    def runtime_program(steps, outputs)
      {"schema_version" => 1, "name" => "m01", "inputs" => {}, "executors" => {"local" => {"adapter" => "local", "config" => {}}}, "steps" => steps, "outputs" => outputs}
    end

    def inspect_runtime(report)
      run_id = report.fetch("run_id")
      check(AgentRuntime::Store.new(@store_root).report(run_id) == report, "Runtime report not durably saved")
      @result["run"]["runtime_run_id"] = run_id
      db = SQLite3::Database.new(File.join(@store_root, "metadata.sqlite3"))
      rows = db.execute("SELECT step_id, attempt, data FROM attempts WHERE run_id=? ORDER BY step_id,attempt", [run_id])
      @result["attempts"] = rows.map { |step_id, attempt, data| {"step_id" => step_id, "attempt" => attempt, "data" => JSON.parse(data)} }
      expected = report.fetch("steps").flat_map { |id, data| data.fetch("attempts").map { |a| [id, a["attempt"], a["status"]] } }.sort
      actual = @result["attempts"].map { |row| [row["step_id"], row["attempt"], row["data"]["status"]] }
      check(expected == actual, "persisted attempt rows disagree with report")
      @result["evidence_paths"]["store"] = @store_root
    ensure
      db&.close
    end

    def runtime_case
      id = @id
      received = []
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |request|
        received << [request.step_id, request.inputs]
        if id.start_with?("HC11.")
          status = if id == "HC11.unknown-no-retry"
            "unknown"
          elsif id == "HC11.exhausted-retry" || request.attempt == 1
            "failure"
          else
            "success"
          end
          result = AgentRuntime::Result.new(status: status, outputs: {"value" => "distinct-output"}, error: {"classification" => "transport"})
          # Advertise the frozen public capability explicitly, including when
          # probing M0's older Result struct. No assertion depends on API presence.
          result.define_singleton_method(:retry_safe) { true }
          result
        elsif request.step_id == "a" && id == "HC10.failed-dependency"
          AgentRuntime::Result.new(status: "failure", outputs: {}, error: {"classification" => "semantic"})
        else
          raise Mismatch, "dependent entered without predecessor" if request.step_id == "b" && received.first.first != "a"
          AgentRuntime::Result.new(status: "success", outputs: {"value" => "distinct-output"})
        end
      end
      steps = if id.start_with?("HC11.")
        [step("a", retries: 1)]
      elsif id == "HC09.inferred-dataflow"
        [step("b", inputs: {"predecessor" => "a.value"}), step("a")]
      else
        [step("b", needs: ["a"]), step("a")]
      end
      report = AgentRuntime::Runtime.new(store: @store, executors: {"local" => adapter}).run(runtime_program(steps, {"value" => "#{steps.first["id"]}.value"}))
      inspect_runtime(report)
      if id.start_with?("HC11.")
        counts = @result["attempts"].map { |row| row["attempt"] }.join(",")
        observe(report["status"], counts)
      elsif id == "HC10.failed-dependency"
        check(received.map(&:first) == ["a"], "failed prerequisite did not gate dependent")
        check(report.dig("steps", "b", "status") == "cancelled" && report["outputs"].empty?, "dependent gained output after failure")
        observe(report["status"], "gated")
      else
        check(received.map(&:first) == %w[a b], "dependency ordering ignored")
        if id == "HC09.inferred-dataflow"
          check(received.last.last == {"predecessor" => "distinct-output"}, "inferred dataflow substituted value")
          producer = report.dig("steps", "a", "outputs", "value")
          consumer = report.dig("steps", "b", "outputs", "value")
          check(consumer["inputs"] == [producer["id"]], "consumer provenance does not reference producer")
        end
        check(@result["attempts"].size == 2, "expected exactly one attempt per step")
        observe(report["status"], "ordered")
      end
    end

    def interruption
      ready = File.join(@root, "ready")
      cancellation = AgentRuntime::Cancellation.new
      process = AgentRuntime::Adapters::ProcessRunner.new
      adapter = Object.new
      adapter.define_singleton_method(:execute) do |request|
        raise Mismatch, "cancelled dependent executed" if request.step_id == "b"
        execution = process.call(argv: [RbConfig.ruby, "--disable-gems", "-e", "File.write(ARGV[0], Process.pid.to_s); sleep 30", ready], cwd: request.workspace, timeout: 4, cancellation: request.cancellation)
        AgentRuntime::Result.new(status: execution.fetch("status"), outputs: {}, logs: execution)
      end
      ir = runtime_program([step("a"), step("b", needs: ["a"])], {"value" => "b.value"})
      thread = Thread.new { AgentRuntime::Runtime.new(store: @store, executors: {"local" => adapter}).run(ir, cancellation: cancellation) }
      Timeout.timeout(5) { sleep 0.005 until File.exist?(ready) }
      cancellation.cancel!
      report = Timeout.timeout(8) { thread.value }
      inspect_runtime(report)
      check(report.dig("steps", "a", "status") == "cancelled", "active attempt not cancelled")
      check(report.dig("steps", "b", "status") == "cancelled" && report["outputs"].empty?, "dependent not cancelled or outputs promoted")
      check(@result["attempts"].map { |r| [r["step_id"], r["attempt"], r["data"]["status"]] } == [["a", 1, "cancelled"]], "interruption attempt count/status wrong")
      dead_process(Integer(File.read(ready)))
      observe(report["status"], "not_evaluated")
    ensure
      cancellation&.cancel!
      thread&.join(6) || thread&.kill&.join
    end

    def dead_process(pid)
      Process.kill(0, pid)
      check(false, "local process survived completion/cancellation")
    rescue Errno::ESRCH
      true
    end
  end

  def self.run(id, root:)
    Case.new(id, root).execute
  end
end
