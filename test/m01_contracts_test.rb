require_relative "test_helper"
require "open3"
require "rbconfig"

class M01ContractsTest < Minitest::Test
  TYPES = %w[text string integer number boolean json file directory repository patch evaluation_report].freeze
  SOURCE = <<~RUBY.freeze
    program :demo do
      input :issue, type: :text
      executor :worker, via: :fake
      step :a, with: :worker, inputs: {issue: :issue}, outputs: {answer: :text}
      step :b, with: :worker, inputs: {answer: 'a.answer'}, outputs: {answer: :text}
      emit :answer, from: 'b.answer'
    end
  RUBY

  def fixture
    {
      "schema_version" => 1, "name" => "demo", "inputs" => {"issue" => "text"},
      "executors" => {"worker" => {"adapter" => "fake", "config" => {}}},
      "steps" => [
        {"id" => "a", "executor" => "worker", "inputs" => {"issue" => "issue"}, "outputs" => {"answer" => "text"}, "needs" => [], "config" => {}, "timeout" => 60, "retries" => 0, "input_types" => {}},
        {"id" => "b", "executor" => "worker", "inputs" => {"answer" => "a.answer"}, "outputs" => {"answer" => "text"}, "needs" => ["a"], "config" => {}, "timeout" => 60, "retries" => 0, "input_types" => {}}
      ],
      "outputs" => {"answer" => "b.answer"}, "config" => {}
    }
  end

  def compile(source = SOURCE)
    in_tmp do |dir|
      path = File.join(dir, "program.rb")
      File.write(path, source)
      AgentRuntime.compile(path)
    end
  end

  def reject_ir(category, &mutation)
    assert_equal fixture, AgentRuntime::Compiler.validate!(fixture), "positive IR control"
    ir = fixture
    mutation.call(ir)
    error = assert_raises(AgentRuntime::Error) { AgentRuntime::Compiler.validate!(ir) }
    assert_match category, error.message
  end

  def test_a01_a14_a32_independent_compile_and_repeat
    assert_equal fixture, compile
    assert_equal fixture, compile
    assert_equal ["a"], compile["steps"][1]["needs"]
  end

  {
    "a02_missing_program" => ["", /program/i],
    "a02_duplicate_program" => ["program(:one) {}\nprogram(:two) {}", /duplicate.*program/i],
    "a03_duplicate_input" => [SOURCE.sub("input :issue, type: :text", "input :issue, type: :text; input 'issue', type: :text"), /duplicate.*issue/i],
    "a03_duplicate_executor" => [SOURCE.sub("executor :worker, via: :fake", "executor :worker, via: :fake; executor 'worker', via: :fake"), /duplicate.*worker/i],
    "a03_duplicate_emit" => [SOURCE.sub("emit :answer, from: 'b.answer'", "emit :answer, from: 'b.answer'; emit 'answer', from: 'b.answer'"), /duplicate.*answer/i]
  }.each do |label, (source, category)|
    define_method("test_#{label}") do
      assert_equal fixture, compile
      error = assert_raises(AgentRuntime::Error) { compile(source) }
      assert_match category, error.message
    end
  end

  INVALID = {
    "a04_duplicate_step" => [/duplicate.*step/i, ->(p) { p["steps"] << p["steps"][0].dup }],
    "a06_missing_executor" => [/executor/i, ->(p) { p["steps"][0]["executor"] = "absent" }],
    "a10_no_step_outputs" => [/output/i, ->(p) { p["steps"][0]["outputs"] = {} }],
    "a10_no_final_outputs" => [/final.*output/i, ->(p) { p["outputs"] = {} }],
    "a12_binding_mismatch" => [/type|mismatch/i, ->(p) { p["steps"][0]["input_types"] = {"issue" => "integer"} }],
    "a13_unknown_binding_type" => [/type/i, ->(p) { p["steps"][0]["input_types"] = {"issue" => "bad_type"} }],
    "a15_missing_dependency" => [/dependency/i, ->(p) { p["steps"][0]["needs"] = ["absent"] }],
    "a18_self_needs" => [/cycle/i, ->(p) { p["steps"][0]["needs"] = ["a"] }],
    "a18_explicit_cycle" => [/cycle/i, ->(p) { p["steps"][0]["needs"] = ["b"] }],
    "a18_inferred_cycle" => [/cycle/i, ->(p) { p["steps"][0]["inputs"] = {"issue" => "b.answer"} }],
    "a18_self_reference" => [/cycle/i, ->(p) { p["steps"][0]["inputs"] = {"issue" => "a.answer"} }]
  }.freeze

  INVALID.each do |label, (category, mutation)|
    define_method("test_#{label}") { reject_ir(category, &mutation) }
  end

  %w[absent absent.answer a.absent a a.answer.extra .answer a.].each_with_index do |ref, index|
    define_method("test_a07_a08_missing_reference_#{index}") do
      reject_ir(/input|reference/i) { |p| p["steps"][0]["inputs"]["issue"] = ref }
    end
    define_method("test_a09_invalid_emit_#{index}") do
      reject_ir(/final.*reference/i) { |p| p["outputs"]["answer"] = ref }
    end
  end

  ["", "1bad", "bad-name", "bad.name"].each_with_index do |name, index|
    {
      "input" => ->(p) { p["inputs"][name] = "text" },
      "executor" => ->(p) { p["executors"][name] = {"adapter" => "fake", "config" => {}} },
      "step" => ->(p) { p["steps"][0]["id"] = name },
      "emit" => ->(p) { p["outputs"][name] = "issue" },
      "output" => ->(p) { p["steps"][0]["outputs"][name] = "text" },
      "binding" => ->(p) { p["steps"][0]["inputs"][name] = "issue" }
    }.each do |position, mutation|
      define_method("test_a05_identifier_#{position}_#{index}") { reject_ir(/identifier/i, &mutation) }
    end
  end

  def test_a05_valid_identifiers_and_cross_namespace_reuse
    %w[a _a A1].each do |name|
      source = "program('name with spaces') { input :#{name}, type: :text; executor :#{name}, via: :future_adapter; step :#{name}, with: :#{name}, inputs: {value: :#{name}}, outputs: {#{name}: :text}; emit :#{name}, from: '#{name}.#{name}' }"
      ir = compile(source)
      assert_equal name, ir["steps"][0]["id"]
      assert_equal "future_adapter", ir["executors"][name]["adapter"]
    end
  end

  TYPES.each do |type|
    define_method("test_a11_type_#{type}") do
      p = fixture
      p["inputs"]["issue"] = type
      p["steps"][0]["outputs"]["answer"] = type
      p["steps"][0]["input_types"] = {"issue" => type}
      p["steps"][1]["input_types"] = {"answer" => type}
      expected = Marshal.load(Marshal.dump(p))
      assert_equal expected, AgentRuntime::Compiler.validate!(p)
    end
  end

  %w[input output].each do |position|
    define_method("test_a11_unknown_#{position}_type") do
      reject_ir(/type/i) do |p|
        ((position == "input") ? p["inputs"] : p["steps"][0]["outputs"])[(position == "input") ? "issue" : "answer"] = "bad_type"
      end
    end
  end

  def test_a12_text_and_string_are_distinct
    reject_ir(/type.*mismatch/i) { |p| p["steps"][0]["input_types"] = {"issue" => "string"} }
  end

  def test_a09_a15_a16_a17_a34_dependency_controls
    p = fixture
    p["outputs"]["answer"] = "issue"
    p["steps"][0]["needs"] = []
    p["steps"][1]["inputs"] = {"answer" => "issue"}
    assert_equal ["a"], AgentRuntime::Compiler.validate!(p)["steps"][1]["needs"]
    c = p["steps"][0].merge("id" => "c")
    p["steps"] << c
    p["steps"][1]["inputs"] = {"answer" => "a.answer"}
    p["steps"][1]["needs"] = %w[c c]
    p["steps"].reverse!
    validated = AgentRuntime::Compiler.validate!(p)
    assert_equal %w[c b a], validated["steps"].map { |s| s["id"] }
    assert_equal %w[a c], validated["steps"][1]["needs"]
    bytes = AgentRuntime::IR.dump(validated)
    assert_equal bytes, AgentRuntime::IR.dump(AgentRuntime::Compiler.validate!(validated))
  end

  def test_a18_diamond_and_mixed_three_node_cycle
    p = fixture
    p["steps"] << p["steps"][1].merge("id" => "c")
    p["steps"] << p["steps"][1].merge("id" => "d", "needs" => %w[b c])
    assert_equal %w[a b c], AgentRuntime::Compiler.validate!(p)["steps"][3]["needs"]
    p["steps"][0]["needs"] = ["c"]
    p["steps"][2]["inputs"] = {"answer" => "b.answer"}
    error = assert_raises(AgentRuntime::Error) { AgentRuntime::Compiler.validate!(p) }
    assert_match(/cycle/i, error.message)
  end

  {"timeout" => [0, -1, "1", nil, Float::INFINITY, Float::NAN], "retries" => [-1, 11, 1.5, "1", nil]}.each do |field, values|
    values.each_with_index do |value, index|
      define_method("test_a19_a20_invalid_#{field}_#{index}") { reject_ir(/limit|timeout|finite/i) { |p| p["steps"][0][field] = value } }
    end
  end

  def test_a19_a20_limit_controls
    [1, 0.25].product([0, 10]).each do |timeout, retries|
      p = fixture
      p["steps"][0].merge!("timeout" => timeout, "retries" => retries)
      expected = Marshal.load(Marshal.dump(p))
      assert_equal expected, AgentRuntime::Compiler.validate!(p)
    end
  end

  [nil, 0, 2, "1"].each_with_index do |version, index|
    define_method("test_a21_schema_#{index}") { reject_ir(/schema/i) { |p| p["schema_version"] = version } }
  end

  [nil, "", 12, []].each_with_index do |name, index|
    define_method("test_a22_identity_#{index}") { reject_ir(/identity|name/i) { |p| p["name"] = name } }
  end

  {"inputs" => [nil, []], "executors" => [nil, []], "steps" => [nil, {}]}.each do |field, values|
    values.each_with_index do |value, index|
      define_method("test_a23_shape_#{field}_#{index}") { reject_ir(/malformed|declaration/i) { |p| p[field] = value } }
    end
  end

  %w[schema_version name inputs executors steps outputs].each do |field|
    define_method("test_a21_a24_missing_top_#{field}") { reject_ir(/schema|identity|malformed|declaration/i) { |p| p.delete(field) } }
  end

  %w[id inputs outputs needs executor timeout retries].each do |field|
    define_method("test_a24_missing_step_#{field}") { reject_ir(/malformed|executor|limit/i) { |p| p["steps"][0].delete(field) } }
  end

  {
    "step" => ->(p) { p["steps"][0] = 3 },
    "bindings" => ->(p) { p["steps"][0]["inputs"] = [] },
    "outputs" => ->(p) { p["steps"][0]["outputs"] = ["text"] },
    "input_types" => ->(p) { p["steps"][0]["input_types"] = [] },
    "needs" => ->(p) { p["steps"][0]["needs"] = "a" },
    "emits" => ->(p) { p["outputs"] = [] },
    "reference" => ->(p) { p["steps"][0]["inputs"]["issue"] = 2 }
  }.each do |label, mutation|
    define_method("test_a25_malformed_#{label}") { reject_ir(/malformed|reference|input|output|need/i, &mutation) }
  end

  %w[program executor step].each do |position|
    [nil, [], "scalar", 3, Object.new].each_with_index do |value, index|
      define_method("test_a27_config_#{position}_#{index}") do
        reject_ir(/config|malformed|JSON/i) do |p|
          target = case position
          when "program" then p
          when "executor" then p["executors"]["worker"]
          else p["steps"][0]
          end
          target["config"] = value
        end
      end
    end
  end

  [nil, "", 2, []].each_with_index do |adapter, index|
    define_method("test_a27_adapter_#{index}") { reject_ir(/adapter|executor|malformed/i) { |p| p["executors"]["worker"]["adapter"] = adapter } }
  end

  def test_a26_symbol_config_normalization
    config = "{mode: :offline, nested: {items: [:ready, true, nil, '雪']}}"
    source = SOURCE.sub("via: :fake", "via: :fake, config: #{config}").sub("outputs: {answer: :text}", "outputs: {answer: :text}, config: #{config}")
    p = compile(source)
    expected = {"mode" => "offline", "nested" => {"items" => ["ready", true, nil, "雪"]}}
    assert_equal expected, p["executors"]["worker"]["config"]
    assert_equal expected, p["steps"][0]["config"]
  end

  {"custom_object" => "{value: Object.new}", "key_collision" => "{mode: :one, 'mode' => :two}"}.each do |label, config|
    define_method("test_a27_dsl_#{label}") do
      assert_equal fixture, compile
      source = SOURCE.sub("via: :fake", "via: :fake, config: #{config}")
      error = assert_raises(AgentRuntime::Error) { compile(source) }
      assert_match(/config|JSON|collision|duplicate|malformed/i, error.message)
    end
  end

  def test_a28_a29_a30_independent_canonical_json_and_digest
    literal = '{"a":{"b":true,"雪":"line\\nnext"},"z":[2,1]}'
    value = {"z" => [2, 1], "a" => {"雪" => "line\nnext", "b" => true}}
    reordered = {"a" => {"b" => true, "雪" => "line\nnext"}, "z" => [2, 1]}
    assert_equal literal, AgentRuntime::IR.dump(value)
    assert_equal literal, AgentRuntime::IR.dump(reordered)
    assert_equal Digest::SHA256.hexdigest(literal), AgentRuntime::IR.digest(value)
    value["z"].reverse!
    refute_equal literal, AgentRuntime::IR.dump(value)
    refute_equal Digest::SHA256.hexdigest(literal), AgentRuntime::IR.digest(value)
  end

  def test_a29_step_array_order_is_significant
    p = fixture
    original = AgentRuntime::IR.dump(p)
    p["steps"].reverse!
    refute_equal original, AgentRuntime::IR.dump(p)
    assert_equal %w[b a], JSON.parse(AgentRuntime::IR.dump(p))["steps"].map { |s| s["id"] }
  end

  def test_a31_roundtrip_against_independent_fixture
    expected = fixture
    expected["steps"][0]["config"] = {"nested" => ["雪", true, nil]}
    source = SOURCE.sub("outputs: {answer: :text}", "outputs: {answer: :text}, config: {nested: ['雪', true, nil]}")
    bytes = AgentRuntime::IR.dump(compile(source))
    decoded = JSON.parse(bytes)
    assert_equal expected, decoded
    assert_equal bytes, AgentRuntime::IR.dump(AgentRuntime::Compiler.validate!(decoded))
    assert_equal AgentRuntime::IR.digest(expected), AgentRuntime::IR.digest(decoded)
  end

  def test_a33_fresh_process_compile_and_serialization
    in_tmp do |dir|
      path = File.join(dir, "program.rb")
      File.write(path, SOURCE)
      script = "require 'agent_runtime'; ir = AgentRuntime.compile(ARGV.fetch(0)); puts AgentRuntime::IR.dump(ir); puts AgentRuntime::IR.digest(ir); puts AgentRuntime::IR.dump({'z'=>[2,1], 'a'=>true})"
      outputs = 2.times.map do
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, path)
        assert status.success?, "child failed: #{stderr}"
        lines = stdout.lines.map(&:chomp)
        assert_equal fixture, JSON.parse(lines.fetch(0))
        assert_equal AgentRuntime::IR.dump(fixture), lines.fetch(0)
        assert_equal Digest::SHA256.hexdigest(lines.fetch(0)), lines.fetch(1)
        assert_equal '{"a":true,"z":[2,1]}', lines.fetch(2)
        stdout
      end
      assert_equal outputs[0], outputs[1]
    end
  end

  def test_a35_compilation_does_not_execute
    in_tmp do |dir|
      sentinel = File.join(dir, "invoked")
      executable = File.join(dir, "sentinel.rb")
      File.write(executable, "#!#{RbConfig.ruby}\nFile.write(#{sentinel.inspect}, 'invoked')\n")
      File.chmod(0o755, executable)
      stdout, stderr, status = Open3.capture3(executable)
      assert status.success?, "sentinel control failed: #{stdout} #{stderr}"
      assert_equal "invoked", File.read(sentinel)
      File.delete(sentinel)
      source = SOURCE.sub("via: :fake", "via: :shell, config: {argv: [#{executable.inspect}]}")
      p = compile(source)
      assert_equal "shell", p["executors"]["worker"]["adapter"]
      assert_equal [executable], p["executors"]["worker"]["config"]["argv"]
      refute_path_exists sentinel, "compile must not invoke the configured executable"
    end
  end

  %w[executor step].each do |omitted|
    define_method("test_a36_optional_#{omitted}_config_executes_and_persists") do
      in_tmp do |dir|
        p = fixture
        p["steps"] = [p["steps"][0]]
        p["outputs"] = {"answer" => "a.answer"}
        executor = p["executors"]["worker"]
        step = p["steps"][0]
        expected = "observable #{omitted} config omission"
        if omitted == "executor"
          executor.delete("config")
          step["config"] = {"values" => {"answer" => expected}}
        else
          step.delete("config")
          executor["config"] = {"values" => {"answer" => expected}}
        end
        assert_equal p, AgentRuntime::Compiler.validate!(Marshal.load(Marshal.dump(p)))
        store = AgentRuntime::Store.new(dir)
        report = AgentRuntime::Runtime.new(store: store).run(p, inputs: {"issue" => "input control"})
        assert_equal "success", report["status"]
        assert_equal expected, store.value(report["outputs"].fetch("answer"))
        persisted = store.report(report["run_id"])
        assert_equal report, persisted
        attempts = persisted.fetch("steps").fetch("a").fetch("attempts")
        assert_equal 1, attempts.length
        assert_equal "success", attempts[0]["status"]
        assert_equal 1, attempts[0]["attempt"]
      end
    end
  end
end
