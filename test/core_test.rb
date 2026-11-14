require_relative "test_helper"

class CoreTest < Minitest::Test
  def compile(source)
    in_tmp do |dir|
      path = File.join(dir, "program.rb")
      File.write(path, source)
      AgentRuntime.compile(path)
    end
  end

  def ir
    compile(<<~RUBY)
      program :demo do
        input :issue, type: :text
        executor :fake, via: :fake
        step :a, with: :fake, inputs: {issue: :issue}, outputs: {answer: :text}, config: {values: {answer: 'ok'}}
        step :b, with: :fake, inputs: {answer: 'a.answer'}, outputs: {answer: :text}, config: {values: {answer: 'done'}}
        emit :answer, from: 'b.answer'
      end
    RUBY
  end

  def test_compilation_and_stable_serialization
    program = ir
    assert_equal ["a"], program["steps"][1]["needs"]
    assert_equal AgentRuntime::IR.dump(program), AgentRuntime::IR.dump(JSON.parse(AgentRuntime::IR.dump(program)))
    assert_equal 64, AgentRuntime::IR.digest(program).size
  end

  def test_validation_errors
    mutations = [
      ->(p) { p["steps"] << p["steps"][0].dup },
      ->(p) { p["steps"][0]["executor"] = "absent" },
      ->(p) { p["steps"][0]["inputs"]["issue"] = "absent" },
      ->(p) { p["steps"][0]["needs"] = ["absent"] },
      ->(p) { p["steps"][0]["needs"] = ["b"] },
      ->(p) { p["inputs"]["issue"] = "bad_type" },
      ->(p) { p["steps"][0]["input_types"] = {"issue" => "integer"} },
      ->(p) { p["outputs"]["answer"] = "a.missing" },
      ->(p) { p["outputs"] = {} }
    ]
    mutations.each do |mutation|
      program = ir
      mutation.call(program)
      assert_raises(AgentRuntime::Error) { AgentRuntime::Compiler.validate!(program) }
    end
  end

  def test_artifact_identity_and_provenance
    in_tmp do |dir|
      store = AgentRuntime::Store.new(dir)
      args = {type: "text", value: "hello", run_id: "r", step_id: "s", attempt: 1}
      a = store.put(**args)
      b = store.put(**args.merge(attempt: 2))
      assert_equal Digest::SHA256.hexdigest("hello"), a["digest"]
      assert_equal a["digest"], b["digest"]
      refute_equal a["id"], b["id"]
      assert_equal "hello", store.value(a)
      assert_equal 2, b["attempt"]
      File.chmod(0o644, a["path"])
      File.write(a["path"], "tampered")
      assert_raises(AgentRuntime::Error) { store.value(a) }
    end
  end

  def test_duplicate_declarations_and_compilation_never_executes_steps
    assert_raises(AgentRuntime::Error) do
      compile("program(:x) { input :a, type: :text; input :a, type: :text }")
    end
    program = compile(<<~RUBY)
      program :no_execution do
        executor :shell, via: :shell, config: {argv: ['nonexistent-command-never-run']}
        step :a, with: :shell, inputs: {}, outputs: {answer: :text}
        emit :answer, from: 'a.answer'
      end
    RUBY
    assert_equal "shell", program["executors"]["shell"]["adapter"]
  end

  def test_runtime_type_validation_and_missing_output
    in_tmp do |dir|
      store = AgentRuntime::Store.new(dir)
      runtime = AgentRuntime::Runtime.new(store: store)
      assert_equal "failure", runtime.run(ir, inputs: {issue: 123})["status"]
      program = ir
      program["steps"][0]["config"]["values"] = {}
      report = runtime.run(program, inputs: {issue: "fix"})
      assert_equal "failure", report["status"]
      assert_equal "output_validation", report["steps"]["a"]["attempts"][0]["error"]["classification"]
      assert_equal "cancelled", report["steps"]["b"]["status"]
    end
  end

  def test_sequential_execution_and_persistence
    in_tmp do |dir|
      store = AgentRuntime::Store.new(dir)
      report = AgentRuntime::Runtime.new(store: store).run(ir, inputs: {"issue" => "fix it"})
      assert_equal "success", report["status"]
      assert_equal "done", store.value(report["outputs"]["answer"])
      assert_equal report, store.report(report["run_id"])
      assert_equal 2, report["steps"].size
    end
  end
end
