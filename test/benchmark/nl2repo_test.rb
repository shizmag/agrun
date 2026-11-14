require_relative "../test_helper"
require_relative "../../lib/agent_runtime/benchmarks/adapters/nl2repo"

class NL2RepoTest < Minitest::Test
  Adapter = AgentRuntime::Benchmarks::Adapters::NL2Repo

  def fixture(root)
    upstream = File.join(root, "upstream")
    FileUtils.mkdir_p(File.join(upstream, "instructions"))
    File.write(File.join(upstream, "instructions/task.md"), "Build a calculator.\n")
    File.write(File.join(upstream, "hidden.py"), "secret oracle")
    git(upstream, "init", "-q")
    git(upstream, "add", ".")
    git(upstream, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
    manifest = {
      "schema_version" => 1, "benchmark" => "nl2repo",
      "repository" => upstream, "revision" => git(upstream, "rev-parse", "HEAD").strip,
      "assets" => {"instructions/task.md" => Digest::SHA256.file(File.join(upstream, "instructions/task.md")).hexdigest},
      "tasks" => [{"id" => "calculator", "instruction_path" => "instructions/task.md", "authorized" => true, "hidden_test" => "hidden.py"}],
      "grading" => {"status" => "blocked", "reason" => "authenticated native collector and controls unavailable"}
    }
    path = File.join(root, "manifest.json")
    File.write(path, JSON.generate(manifest))
    [Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo")), manifest, path]
  end

  def git(root, *args)
    output, status = Open3.capture2e("git", "-C", root, *args)
    raise output unless status.success?
    output
  end

  def test_dry_run_is_offline_and_missing_tasks_remain_visible
    in_tmp do |root|
      adapter, = fixture(root)
      report = adapter.prepare(dry_run: true)
      assert_equal "missing", report.fetch("state")
      refute File.exist?(File.join(root, ".agru"))
      assert_nil report["download_bytes"]
      assert_equal "clone", report.fetch("planned_actions").first.fetch("action")
      assert_equal "missing", report.fetch("assets").first.fetch("state")
      assert_equal false, report.fetch("runnable")
      assert_equal "blocked", report.fetch("grader_status")
      task = adapter.load_task("calculator")
      assert task.frozen?
      assert task.fetch("metadata").frozen?
      assert_equal "missing", task.fetch("availability")
      assert_nil task["instruction"]
      assert_equal %w[availability benchmark id instruction metadata specification_digest unavailable_reason], task.keys.sort
      assert_raises(KeyError) { adapter.load_task("unknown") }
      assert_raises(ArgumentError) { adapter.prepare }
    end
  end

  def test_import_pins_head_assets_and_repeated_preparation_without_replacing
    in_tmp do |root|
      adapter, manifest, = fixture(root)
      assert_equal "verified", adapter.prepare(allow_download: true).fetch("state")
      assert_equal manifest.fetch("revision"), git(adapter.dataset_path, "rev-parse", "HEAD").strip
      assert_equal "verified", adapter.prepare(allow_download: true).fetch("state")
      File.write(File.join(adapter.dataset_path, "instructions/task.md"), "tampered")
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
      assert_equal "tampered", File.read(File.join(adapter.dataset_path, "instructions/task.md"))
    end
  end

  def test_generation_workspace_contains_only_authorized_instruction_and_empty_git_repo
    in_tmp do |root|
      adapter, = fixture(root)
      adapter.prepare(allow_download: true)
      task = adapter.load_task("calculator")
      assert_equal "Build a calculator.\n", task.fetch("instruction")
      refute_includes JSON.generate(task), "hidden.py"
      workspace = File.join(root, "solver")
      prepared = adapter.prepare_solver_workspace(task: task, workspace: workspace)
      assert File.directory?(File.join(prepared.fetch("repository"), ".git"))
      assert_equal [".git"], Dir.children(prepared.fetch("repository"))
      assert_equal task.fetch("instruction"), File.read(prepared.fetch("instruction_path"))
      assert_raises(ArgumentError) { adapter.prepare_solver_workspace(task: task, workspace: workspace) }
      forged = task.merge("instruction" => "leak")
      assert_raises(ArgumentError) { adapter.prepare_solver_workspace(task: forged, workspace: File.join(root, "forged")) }
    end
  end

  def test_manifest_and_head_tampering_fail_closed
    in_tmp do |root|
      adapter, manifest, path = fixture(root)
      adapter.prepare(allow_download: true)
      manifest["tasks"].first["authorized"] = false
      File.write(path, JSON.generate(manifest))
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
    end
    in_tmp do |root|
      adapter, = fixture(root)
      adapter.prepare(allow_download: true)
      File.write(File.join(adapter.dataset_path, "extra"), "unexpected")
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
    end
  end

  def test_grading_is_unavailable_even_when_supplied_native_scores
    in_tmp do |root|
      adapter, = fixture(root)
      adapter.prepare(allow_download: true)
      store = AgentRuntime::Store.new(File.join(root, "store"))
      adapter.instance_variable_set(:@store, store)
      repo = File.join(root, "submitted")
      FileUtils.mkdir_p(repo)
      artifact = store.put(type: "repository", value: repo, run_id: "nl2repo-test", step_id: "submit", attempt: 1)
      request = adapter.prepare_grading_request(task: adapter.load_task("calculator"), submission: artifact, limits: {"timeout" => 10})
      assert_equal artifact.fetch("id"), request.fetch("submission_id")
      assert_equal artifact.fetch("digest"), request.fetch("submission_digest")
      assert_raises(ArgumentError) { adapter.prepare_grading_request(task: adapter.load_task("calculator"), submission: artifact.merge("digest" => "forged"), limits: {"timeout" => 10}) }
      assert_raises(ArgumentError) { adapter.prepare_grading_request(task: adapter.load_task("calculator"), submission: artifact, limits: {"timeout" => 0}) }
      assert_raises(ArgumentError) { adapter.grade_submission(request.merge("submission_digest" => "forged")) }
      result = adapter.grade_submission(request)
      assert_equal "unavailable", result.fetch("status")
      assert_equal "unavailable", result.fetch("execution_status")
      assert_equal "untrusted", result.fetch("trust")
      assert_nil result.fetch("score")
      assert_nil adapter.normalize_score({"score" => 1.0})
    end
  end

  def test_audited_manifest_schema_is_supported_without_export_authorization_or_image_guesses
    in_tmp do |root|
      path = File.expand_path("../../benchmarks/nl2repo/manifest.json", __dir__)
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"))
      report = adapter.prepare(dry_run: true)
      assert_equal "781a1da1ee41fb8edb0bed22f586d69111610edf", adapter.identity.fetch("revision")
      assert_equal 104, adapter.list_tasks.length
      assert_equal "excluded", adapter.load_task("aiofiles").fetch("availability")
      assert_nil adapter.load_task("aiofiles").fetch("instruction")
      image = report.fetch("required_images").find { |row| row.fetch("task_id") == "aiofiles" }
      assert_nil image.fetch("digest")
      assert_equal "unsupported_unpinned_digest", image.fetch("availability")
      assert_nil image.fetch("disk_bytes")
      assert_equal "https://github.com/multimodal-art-projection/NL2RepoBench", report.fetch("planned_actions").first.fetch("source")
      refute File.exist?(File.join(root, ".agru"))
    end
  end

  def test_wrong_revision_and_symlinked_assets_cannot_be_prepared
    in_tmp do |root|
      _, manifest, path = fixture(root)
      manifest["revision"] = "0" * 40
      File.write(path, JSON.generate(manifest))
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"))
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
      refute File.exist?(File.join(root, ".agru/nl2repo/verified.json"))
      assert_equal "downloaded", adapter.prepare(dry_run: true).fetch("state")
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
    end
    in_tmp do |root|
      adapter, = fixture(root)
      adapter.prepare(allow_download: true)
      instruction = File.join(adapter.dataset_path, "instructions/task.md")
      File.unlink(instruction)
      File.symlink(File.join(root, "upstream/instructions/task.md"), instruction)
      assert_raises(ArgumentError) { adapter.load_task("calculator") }
    end
  end

  def test_asset_digest_and_receipt_mismatches_do_not_silently_repair_imports
    in_tmp do |root|
      _, manifest, path = fixture(root)
      manifest["assets"]["instructions/task.md"] = "0" * 64
      File.write(path, JSON.generate(manifest))
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"))
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
      refute File.exist?(File.join(root, ".agru/nl2repo/verified.json"))
    end
    in_tmp do |root|
      adapter, = fixture(root)
      adapter.prepare(allow_download: true)
      File.write(File.join(root, ".agru/nl2repo/verified.json"), "{}")
      assert_raises(ArgumentError) { adapter.prepare(allow_download: true) }
      assert_equal "{}", File.read(File.join(root, ".agru/nl2repo/verified.json"))
    end
  end

  def test_unauthorized_tasks_are_excluded_and_paths_cannot_escape_dataset
    in_tmp do |root|
      _, manifest, path = fixture(root)
      manifest["tasks"].first["authorized"] = false
      File.write(path, JSON.generate(manifest))
      adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"))
      assert_equal "excluded", adapter.load_task("calculator").fetch("availability")
      manifest["tasks"].first["instruction_path"] = "../secret"
      File.write(path, JSON.generate(manifest))
      assert_raises(ArgumentError) { Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo")) }
    end
  end
end
