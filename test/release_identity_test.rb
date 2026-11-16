require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/release_identity"

class ReleaseIdentityTest < Minitest::Test
  def test_identity_detects_changed_runtime_bytes_even_at_same_revision
    in_tmp do |root|
      system("git", "init", "-q", root, exception: true)
      system("git", "-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "fixture", exception: true)
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "runtime.rb"), "original")
      identity = AgentRuntime::Benchmarks::ReleaseIdentity.capture(root: root)
      assert AgentRuntime::Benchmarks::ReleaseIdentity.verify!(identity, root: root)
      File.write(File.join(root, "lib", "runtime.rb"), "changed")
      assert_raises(ArgumentError) { AgentRuntime::Benchmarks::ReleaseIdentity.verify!(identity, root: root) }
    end
  end
end
