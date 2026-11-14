require_relative "nl2repo_test"

class NL2RepoLocalSpecificationTest < NL2RepoTest
  def local_fixture(root)
    _, manifest, path = fixture(root)
    manifest.fetch("tasks").first["authorized"] = false
    manifest["license"] = {"redistribution_authorized" => false}
    File.write(path, JSON.generate(manifest))
    adapter = Adapter.new(manifest_path: path, root: File.join(root, ".agru/nl2repo"))
    adapter.prepare(allow_download: true)
    [adapter, path]
  end

  def test_local_consent_exports_only_pinned_instruction_without_changing_manifest
    in_tmp do |root|
      adapter, path = local_fixture(root)
      before = File.binread(path)
      assert_nil adapter.load_task("calculator").fetch("instruction")
      adapter.prepare(task: "calculator", allow_local_specification_use: true)
      task = adapter.load_task("calculator")
      assert_equal "Build a calculator.\n", task.fetch("instruction")
      workspace = File.join(root, "solver")
      adapter.prepare_solver_workspace(task: task, workspace: workspace)
      assert_equal ["INSTRUCTION.md", "repository"], Dir.children(workspace).sort
      assert_equal before, File.binread(path)
      assert_equal false, JSON.parse(File.read(path)).fetch("license").fetch("redistribution_authorized")
    end
  end

  def test_dry_run_does_not_grant_local_consent
    in_tmp do |root|
      adapter, = local_fixture(root)
      adapter.prepare(task: "calculator", allow_local_specification_use: true, dry_run: true)
      assert_nil adapter.load_task("calculator").fetch("instruction")
    end
  end

  def test_receipt_corruption_and_changed_source_fail_closed
    in_tmp do |root|
      adapter, = local_fixture(root)
      adapter.prepare(task: "calculator", allow_local_specification_use: true)
      path = File.join(root, ".agru/nl2repo/local-specification-use.json")
      receipt = JSON.parse(File.read(path))
      receipt.fetch("authorization")["specification_digest"] = "0" * 64
      File.write(path, JSON.generate(receipt))
      assert_raises(ArgumentError) { adapter.load_task("calculator") }
      File.unlink(path)
      File.write(File.join(adapter.dataset_path, "instructions/task.md"), "tampered")
      assert_raises(ArgumentError) { adapter.prepare(task: "calculator", allow_local_specification_use: true) }
    end
  end
end
