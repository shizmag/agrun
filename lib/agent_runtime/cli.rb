require "json"
require "optparse"
require "tmpdir"
require "rbconfig"
require_relative "benchmarks"

module AgentRuntime
  class CLI
    def self.start(argv = ARGV)
      new.run(argv)
    end

    def run(argv)
      command = argv.shift
      return Benchmarks::CLI.new.run(argv) if command == "bench"
      if command == "trace"
        require_relative "tracing/cli"
        return Tracing::CLI.new.run(argv)
      end
      options = {root: ".agru", suite: "demo", live: false, solver: "good"}
      parser = OptionParser.new do |opts|
        opts.on("--offline") { options[:live] = false }
        opts.on("--live") { options[:live] = true }
        opts.on("--trace-root PATH") { |v| options[:trace_root] = v }
        opts.on("--trace-raw") { options[:trace_raw] = true }
        opts.on("--authorize-raw") { options[:authorize_raw] = true }
        opts.on("--root PATH") { |v| options[:root] = v }
        opts.on("--suite NAME") { |v| options[:suite] = v }
        opts.on("--solver NAME") { |v| options[:solver] = v }
        opts.on("--model NAME") { |v| options[:model] = v }
        opts.on("--program PATH") { |v| options[:program] = v }
        opts.on("--inputs PATH") { |v| options[:inputs] = v }
        opts.on("--repetitions N", Integer) { |v| options[:repetitions] = v }
      end
      parser.parse!(argv)
      raise ArgumentError, "--trace-raw requires --authorize-raw and --trace-root" if options[:trace_raw] && (!options[:authorize_raw] || !options[:trace_root])
      root = File.expand_path(options[:root])
      case command
      when "doctor"
        available = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |p| File.executable?(File.join(p, "git")) }
        optional = %w[opencode openspec serena uvx].to_h do |tool|
          path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, tool) }.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
          [tool, {"available" => !path.nil?, "path" => path}]
        end
        puts JSON.pretty_generate({"ruby" => RUBY_DESCRIPTION, "git" => available, "offline_default" => true,
          "live" => options[:live], "store" => root, "optional_tools" => optional, "serena_benchmark_enabled" => false})
        available ? 0 : 1
      when "validate", "graph"
        ir = AgentRuntime.compile(argv.shift || options[:program] || default_program)
        Compiler.validate!(ir)
        puts((command == "graph") ? JSON.pretty_generate(ir) : JSON.generate({"valid" => true, "digest" => IR.digest(ir)}))
        0
      when "run"
        store = Store.new(File.join(root, "store"))
        if options[:trace_root]
          trace_store = Tracing::Store.new(options[:trace_root], raw_content: !!options[:trace_raw])
          store.tracing = Tracing::Session.new(trace: trace_store, artifacts: store, raw_content: !!options[:trace_raw])
        end
        ir = AgentRuntime.compile(argv.shift || options[:program] || default_program)
        gate_live!(ir, options[:live])
        inputs = options[:inputs] ? JSON.parse(File.read(options[:inputs])) : fixture_inputs(root)
        report = Runtime.new(store: store).run(ir, inputs: inputs, workspace: File.join(root, "runtime", SecureRandom.uuid))
        puts JSON.pretty_generate(report)
        (report["status"] == "success") ? 0 : 1
      when "benchmark"
        raise ArgumentError, "unknown suite: #{options[:suite]}" unless options[:suite] == "demo"
        store = Store.new(File.join(root, "store"))
        if options[:trace_root]
          trace_store = Tracing::Store.new(options[:trace_root], raw_content: !!options[:trace_raw])
          store.tracing = Tracing::Session.new(trace: trace_store, artifacts: store, raw_content: !!options[:trace_raw])
        end
        task = fixture(root)
        if options[:solver] == "all"
          solvers = {"fake-good" => Benchmarks::Solvers::Fake.new, "fake-bad" => Benchmarks::Solvers::Fake.new(good: false), "dsl" => Benchmarks::Solvers::DSL.new(program: options[:program] || default_program, store: store)}
          reports = Benchmarks::Runner.new(store: store, root: File.join(root, "benchmarks")).matrix(tasks: [task], solvers: solvers, repetitions: options.fetch(:repetitions, 1))
          puts JSON.pretty_generate({"mock" => true, "runs" => reports.map { |report| {"run_id" => report["run_id"], "solver" => report["solver_id"], "repetition" => report["repetition"], "status" => report["status"], "verdict" => report.dig("evaluation", "verdict")} }})
          expected = reports.all? do |report|
            verdict = (report["solver_id"] == "fake-bad") ? "fail" : "pass"
            report["status"] == "success" && report.dig("evaluation", "verdict") == verdict
          end
          return expected ? 0 : 1
        end
        solver = case options[:solver]
        when "good" then Benchmarks::Solvers::Fake.new
        when "bad" then Benchmarks::Solvers::Fake.new(good: false)
        when "opencode" then Benchmarks::Solvers::OpenCode.new(live: options[:live])
        when "dsl" then Benchmarks::Solvers::DSL.new(program: options[:program] || default_program, store: store, live: options[:live])
        else raise ArgumentError, "unknown solver: #{options[:solver]}"
        end
        report = Benchmarks::Runner.new(store: store, root: File.join(root, "benchmarks")).run(task: task,
          solver: solver, solver_id: options[:solver], model: options[:model], budget: {"timeout" => 120, "evaluation_timeout" => 30})
        puts JSON.pretty_generate(report)
        (report.dig("evaluation", "verdict") == "pass") ? 0 : 1
      when "report"
        id = argv.shift or raise ArgumentError, "report requires a run ID"
        report = Store.new(File.join(root, "store")).report(id)
        raise ArgumentError, "run not found: #{id}" unless report
        puts JSON.pretty_generate(report)
        0
      else
        warn "Usage: agru doctor|validate|graph|run|benchmark|report [options]"
        2
      end
    rescue => error
      warn "#{error.class}: #{error.message}"
      1
    ensure
      trace_store&.close
    end

    private

    def default_program
      File.expand_path("../../programs/demo.rb", __dir__)
    end

    def fixture(root)
      parent = File.join(root, "fixtures", SecureRandom.uuid)
      Benchmarks::Fixture.demo(root: parent)
    end

    def fixture_inputs(root)
      {"repository" => fixture(root).repository}
    end

    def gate_live!(ir, live)
      executors = ir.fetch("executors", {})
      entries = executors.is_a?(Hash) ? executors.values : executors
      entries.each do |entry|
        next unless entry["adapter"].to_s == "opencode"
        raise ArgumentError, "OpenCode requires explicit --live" unless live
        entry["config"] ||= {}
        entry["config"]["live"] = true
      end
      ir.fetch("steps").each do |step|
        next unless executors.fetch(step.fetch("executor"))["adapter"] == "opencode"
        step["config"] ||= {}
        step["config"]["live"] = live
      end
    end
  end
end
