# Read-only offline reconstruction: never invokes a grader, container or report renderer.
require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks/audited_results"
require_relative "../lib/agent_runtime/benchmarks/nl2repo_test_manifest"
require "sqlite3"
require "optparse"

class M11cEvidenceReconstruction
  COUNTS = %w[expected collected executed passed failed skipped].freeze
  REFERENCE_SHA256 = "d8f1cc7e269fe908cae965fb9338d3625c56c9e56a35435dcb6f78ee74a53e0a"

  def initialize(root)
    @root = File.expand_path(root)
    @db = SQLite3::Database.new(File.join(@root, "metadata.sqlite3"), readonly: true)
    @manifest = AgentRuntime::Benchmarks::NL2RepoTestManifest.new
    @artifacts = {}
    @checks = 0
    @holes = []
  end

  def check(condition, message)
    @checks += 1
    raise message unless condition
  end

  def object(artifact)
    digest = artifact.fetch("digest")
    check(/\A[0-9a-f]{64}\z/.match?(digest), "invalid artifact digest")
    saved = JSON.parse(@db.get_first_value("SELECT data FROM artifacts WHERE id = ?", [artifact.fetch("id")]) || "null")
    check(saved == artifact, "artifact metadata disagrees with Store")
    bytes = File.binread(File.join(@root, "objects", digest))
    check(Digest::SHA256.hexdigest(bytes) == digest, "artifact bytes changed: #{digest}")
    @artifacts[digest] = true
    bytes
  end

  def same(actual, expected, label)
    expected.each { |key, value| check(actual[key] == value, "#{label}: #{key}: #{actual[key].inspect} != #{value.inspect}") }
  end

  # Report CSV uses quoted fields (including embedded JSON/newlines). Ruby 4's
  # optional csv gem is deliberately not required by this offline-only script.
  def csv_rows(bytes)
    rest = bytes.dup
    rows = []
    row = []
    until rest.empty?
      match = /\A"((?:[^"]|"")*)"(,|\r?\n|\z)/.match(rest)
      check(!match.nil?, "unsupported or malformed quoted report CSV")
      row << match[1].gsub('""', '"')
      rest = rest[match[0].length..]
      unless match[2] == ","
        rows << row
        row = []
      end
    end
    check(row.empty? && rows.length >= 2, "incomplete CSV")
    header = rows.shift
    check(header.uniq == header, "duplicate CSV header")
    rows.map do |values|
      check(values.length == header.length, "CSV column mismatch")
      header.zip(values).to_h
    end
  end

  def parse_evidence(evidence, binding, role)
    bytes = object(evidence.fetch("report_artifact"))
    transport = JSON.parse(object(evidence.fetch("process_artifact")))
    process = transport.fetch("process")
    same(evidence, {"report_sha256" => Digest::SHA256.hexdigest(bytes), "process" => process}, "#{role} transport")
    doc = JSON.parse(bytes)
    actual = doc.fetch("binding")
    role_binding = binding.merge("role" => role)
    role_binding["reference_sha256"] = REFERENCE_SHA256 if role == "reference"
    same(actual, role_binding, "#{role} binding")
    check(actual.fetch("attempt_id").is_a?(String) && !actual["attempt_id"].empty?, "missing transport attempt")
    check(actual.keys.sort == (role_binding.keys + %w[attempt_id]).sort, "unexpected binding fields")
    check(transport.fetch("binding") == actual, "process artifact binding mismatch")
    check(transport.fetch("report_artifact") == evidence.fetch("report_artifact"), "process artifact report mismatch")
    check(transport.fetch("report_copy").fetch("status") == "success", "report copy failed")
    parsed = AgentRuntime::Benchmarks::AuditedResults.parse(bytes: bytes,
      expected_nodeids: @manifest.expected_nodeids, expected_binding: actual, process: process)
    check(parsed["status"] != "invalid", "#{role} raw report invalid: #{parsed.inspect}")
    [parsed, actual.fetch("attempt_id")]
  end

  def reconstruct(cell, attempt)
    request = attempt.fetch("request")
    binding = request.fetch("audited_binding")
    ids = @manifest.expected_nodeids
    check(request.fetch("expected_nodeids") == ids, "request population differs from pinned manifest")
    same(binding, {"protocol" => "nl2repo-audited-v2", "test_manifest_digest" => @manifest.digest,
      "test_source_sha256" => @manifest.identity.fetch("test_source_sha256"),
      "submission_digest" => cell.fetch("submission").fetch("digest"),
      "specification_digest" => request.fetch("specification_digest"),
      "task_id" => request.fetch("task_id"), "benchmark_revision" => request.fetch("benchmark").fetch("revision")}, "request")
    check(request["submission_digest"] == binding["submission_digest"], "submission request mismatch")
    raw = attempt.fetch("raw")
    artifacts = raw.fetch("artifacts")
    reference, reference_attempt = parse_evidence(artifacts.fetch("reference_evidence"), binding, "reference")
    candidate, candidate_attempt = parse_evidence(artifacts.fetch("candidate_evidence"), binding, "candidate")
    check(reference_attempt == candidate_attempt, "reference and candidate are from different preflight attempts")
    check(reference["status"] == "valid" && reference.fetch("tests").values.all? { |v| v == "passed" }, "reference preflight did not pass")
    inventory = JSON.parse(object(cell.fetch("submission")))
    if candidate["status"] == "collection_failure"
      check(candidate.fetch("collected").empty?, "partial collection cannot establish absence")
      check(inventory.none? { |entry| entry["path"] == "retrying.py" || entry["path"].start_with?("retrying/") }, "candidate module exists")
      errors = candidate.fetch("collection_errors")
      check(!errors.empty? && errors.all? { |e| e["nodeid"] == "test_retrying.py" && e["exception"]["type"] == "ModuleNotFoundError" && e["exception"]["module"] == "retrying" }, "collection failure is not proven candidate absence")
      counts = COUNTS.to_h { |key| [key, 0] }.merge("expected" => ids.length)
      basis = "candidate_collection_failure"
    else
      check(candidate["status"] == "valid", "candidate has no complete results")
      outcomes = candidate.fetch("tests").values
      counts = {"expected" => ids.length, "collected" => candidate.fetch("tests").length,
                "executed" => candidate.fetch("executed"), "passed" => outcomes.count("passed"),
                "failed" => outcomes.count("failed") + outcomes.count("error"), "skipped" => outcomes.count("skipped")}
      basis = "validated_quality_result"
    end
    expected = counts.merge("total" => ids.length, "score" => counts.fetch("passed").fdiv(ids.length),
      "verdict" => (counts.fetch("passed") == ids.length) ? "pass" : "fail",
      "protocol" => "nl2repo-audited-v2", "quality_basis" => basis, "execution_status" => "success")
    same(raw, expected.merge("trust" => "audited", "trust_scope" => "benign_ordinary_submissions"), "raw promoted measurement")
    same(attempt.fetch("result"), expected, "persisted normalized attempt")
    expected
  end

  def verify_exports(run, expected)
    retained = File.join(@root, "exports", run.fetch("run_id"), "report.json")
    paths = File.exist?(retained) ? [retained] : Dir.glob(File.join(@root, "*.json"))
    exports = paths.filter_map do |path|
      doc = JSON.parse(File.read(path))
      [path, doc] if doc.is_a?(Hash) && doc["kind"] == "experiment" && doc["run_id"] == run["run_id"]
    end
    if exports.empty?
      @holes << "#{run.fetch("run_id")}: no persisted JSON/CSV/Markdown export set; SQLite attempts reconstructed"
      return []
    end
    exports.map do |path, doc|
      same(doc.fetch("cells").fetch(0), expected, "JSON cell")
      same(doc.fetch("summary").fetch("per_task_results").fetch("retrying").fetch(0), expected, "JSON per-task result")
      arm = doc.fetch("summary").fetch("arms").fetch(0)
      same(arm, {"protocol" => expected["protocol"], "quality_basis" => expected["quality_basis"],
        "macro_score" => expected["score"], "valid_cells" => 1, "invalid_cells" => 0,
        "included_tasks" => ["retrying"], "excluded_tasks" => [], "conditional_denominator" => 1}, "JSON aggregate")
      same(arm.fetch("pooled_counts"), {"passed" => expected["passed"], "total" => expected["total"], "coverage" => 1}, "JSON pooled counts")
      coverage = COUNTS.to_h { |key| [key, {"total" => expected[key], "known_cells" => 1}] }
      check(arm.fetch("count_evidence") == coverage, "JSON count coverage mismatch")
      same(doc.fetch("summary").fetch("evaluation_completion"), {"completed" => 1, "planned" => 1, "fraction" => 1.0}, "JSON completion")
      base = path.delete_suffix(".json")
      csv = csv_rows(File.read("#{base}.csv"))
      check(csv.length == 1, "unexpected CSV cell count")
      same(csv.first.to_h, expected.to_h { |key, value| [key, value.to_s] }, "CSV")
      markdown = File.read("#{base}.markdown")
      check(markdown.include?("# Experiment #{run.fetch("run_id")}"), "Markdown run identity mismatch")
      line = markdown.lines.find { |text| text.start_with?("| repository-submission |") }
      check(!line.nil?, "missing Markdown arm")
      columns = line.split("|").map(&:strip)
      check(columns[3..8] == [expected["protocol"], expected["quality_basis"], expected["score"].to_s, "retrying", "", "1 / 0"], "Markdown quality mismatch")
      check(JSON.parse(columns.fetch(9)) == coverage, "Markdown counts mismatch")
      # These control exports have one task and one repetition: macro and micro coincide.
      {"json" => path.delete_prefix("#{@root}/"), "csv" => "#{base}.csv".delete_prefix("#{@root}/"),
       "markdown" => "#{base}.markdown".delete_prefix("#{@root}/")}
    end
  end

  def call
    @db.execute("BEGIN")
    results = []
    excluded = []
    @db.execute("SELECT id, data FROM runs ORDER BY id").each do |id, bytes|
      run = JSON.parse(bytes)
      next unless run["kind"] == "experiment"
      if run.fetch("cells").any? { |cell| cell["score"].nil? }
        excluded << {"experiment_id" => id, "reason" => "historical unscored experiment; no scored reconstruction claim"}
        next
      end
      check(run.fetch("cells").length == 1 && run.fetch("manifest").fetch("repetitions") == 1, "only single-cell controls supported")
      cell = run.fetch("cells").first
      attempts = cell.fetch("grading_attempts")
      check(!attempts.empty?, "missing grading attempts")
      derived = attempts.map { |attempt| reconstruct(cell, attempt) }
      same(cell, derived.last, "SQLite active cell")
      if id.include?("reference")
        inventory = JSON.parse(object(cell.fetch("submission")))
        source = inventory.find { |entry| entry["path"] == "retrying.py" }
        check(source && Digest::SHA256.hexdigest(source.fetch("content").unpack1("m0")) == REFERENCE_SHA256, "reference control differs from pinned implementation")
      end
      results << {"experiment_id" => id, "attempts_verified" => attempts.length,
                  "reconstructed" => derived.last, "exports_verified" => verify_exports(run, derived.last)}
    end
    check(!results.empty?, "no scored experiments reconstructed")
    {"status" => "pass", "scope" => "offline single-task controls; not independent collector implementation or hostile authentication",
     "manifest_sha256" => @manifest.digest, "assertions" => @checks, "unique_objects_verified" => @artifacts.length,
     "experiments" => results, "excluded_unscored" => excluded, "evidence_holes" => @holes}
  ensure
    @db.execute("ROLLBACK") if @db.transaction_active?
    @db.close
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new { |opts| opts.on("--root PATH") { |path| options[:root] = path } }
  parser.parse!
  abort "usage: ruby script/m11c_reconstruct_evidence.rb --root PATH" unless options[:root] && ARGV.empty?
  begin
    puts JSON.pretty_generate(M11cEvidenceReconstruction.new(options.fetch(:root)).call)
  rescue => error
    warn "evidence reconstruction failed: #{error.class}: #{error.message}"
    exit 1
  end
end
