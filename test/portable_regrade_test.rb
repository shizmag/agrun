require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/portable_regrade"

class PortableRegradeTest < Minitest::Test
  def test_rejects_invalid_bundle_before_creating_store
    in_tmp do |root|
      fresh = File.join(root, "fresh")
      assert_raises(Errno::ENOENT) do
        AgentRuntime::Benchmarks::PortableRegrade.new.run(bundle: File.join(root, "missing"), root: fresh, assets: root)
      end
      refute File.exist?(fresh)
    end
  end

  def test_restores_bytes_and_executable_modes_without_original_store
    in_tmp do |root|
      store = AgentRuntime::Store.new(File.join(root, "new-store"))
      manifest = [{"path" => "bin/tool", "content" => ["hello\n"].pack("m0"), "executable" => true},
        {"path" => "README", "content" => ["world\n"].pack("m0"), "executable" => false}].sort_by { |entry| entry.fetch("path") }
      submission = {"repository_manifest" => manifest, "submission_digest" => AgentRuntime::IR.digest(manifest)}
      artifact = AgentRuntime::Benchmarks::PortableRegrade.new.send(:restore, store, submission)
      assert_equal submission.fetch("submission_digest"), artifact.fetch("digest")
      assert_equal "hello\n", File.binread(File.join(artifact.fetch("path"), "bin/tool"))
      assert File.executable?(File.join(artifact.fetch("path"), "bin/tool"))
      refute File.executable?(File.join(artifact.fetch("path"), "README"))
    end
  end
end
