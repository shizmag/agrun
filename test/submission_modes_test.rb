require_relative "test_helper"
require_relative "../lib/agent_runtime/benchmarks/submission"

class SubmissionModesTest < Minitest::Test
  def test_mode_change_during_second_repository_capture_is_rejected
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      File.write(File.join(source, "file"), "same")
      File.chmod(0o644, File.join(source, "file"))
      store = AgentRuntime::Store.new(File.join(root, "store"))
      repository_puts = 0
      original_put = store.method(:put)
      store.define_singleton_method(:put) do |**arguments|
        result = original_put.call(**arguments)
        if arguments.fetch(:type) == "repository"
          repository_puts += 1
          File.chmod(0o444, File.join(source, "file")) if repository_puts == 2
        end
        result
      end
      error = assert_raises(AgentRuntime::Error) do
        AgentRuntime::Benchmarks::Submission.new(store: store).capture(repository: source, preserve_modes: true)
      end
      assert_equal "submission modes changed during capture", error.message
    end
  end

  def test_invalid_canonical_sidecars_are_rejected
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      File.write(File.join(source, "file"), "same")
      store = AgentRuntime::Store.new(File.join(root, "store"))
      boundary = AgentRuntime::Benchmarks::Submission.new(store: store)
      original = boundary.capture(repository: source, preserve_modes: true)
      reference = original.fetch("metadata").fetch("mode_evidence")
      evidence = store.value(store.artifact(reference.fetch("id")))
      mutations = [
        ->(data) { data["content_digest"] = "0" * 64 },
        ->(data) { data["entries"].reject! { |entry| entry["path"] == "file" } },
        ->(data) { data["entries"] << {"path" => "extra", "kind" => "file", "mode" => 0o644} },
        ->(data) { data["entries"].first["mode"] = 0o4755 },
        ->(data) { data["entries"] << {"path" => "../escape", "kind" => "directory", "mode" => 0o755} },
        ->(data) { data["entries"] << data["entries"].last.dup },
        ->(data) { data["entries"].last["path"] = "./file" },
        ->(data) { data["entries"].last["kind"] = "directory" }
      ]
      mutations.each do |mutate|
        data = Marshal.load(Marshal.dump(evidence))
        mutate.call(data)
        sidecar = store.put(type: "json", value: data, run_id: "bad", step_id: "modes", attempt: 1)
        bad = store.put(type: "repository", value: source, run_id: "bad", step_id: "submission", attempt: 1,
          metadata: {"mode_evidence" => sidecar.slice("id", "digest")})
        assert_raises(AgentRuntime::Error) { boundary.verify(bad) }
      end
      bad = store.put(type: "repository", value: source, run_id: "bad", step_id: "digest", attempt: 1,
        metadata: {"mode_evidence" => reference.merge("digest" => "0" * 64)})
      assert_raises(AgentRuntime::Error) { boundary.verify(bad) }
      assert_equal original, boundary.verify(original)
    end
  end

  def test_mode_distinct_equal_content_keeps_previous_snapshot_immutable
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      File.write(File.join(source, "file"), "same")
      File.chmod(0o644, File.join(source, "file"))
      store = AgentRuntime::Store.new(File.join(root, "store"))
      boundary = AgentRuntime::Benchmarks::Submission.new(store: store)
      first = boundary.capture(repository: source, preserve_modes: true)
      first_copy = File.join(root, "first")
      boundary.materialize(first, destination: first_copy)
      stored_mode = File.stat(File.join(first.fetch("path"), "file")).mode
      File.chmod(0o444, File.join(source, "file"))
      second = boundary.capture(repository: source, preserve_modes: true)
      legacy = boundary.capture(repository: source)
      assert_equal first.fetch("digest"), second.fetch("digest")
      assert_equal first.fetch("digest"), legacy.fetch("digest")
      refute_equal first.fetch("metadata").fetch("mode_evidence").fetch("digest"), second.fetch("metadata").fetch("mode_evidence").fetch("digest")
      assert_equal stored_mode, File.stat(File.join(first.fetch("path"), "file")).mode
      assert boundary.verify_snapshot!(first, first_copy)
      assert_equal 0o644, File.stat(File.join(first_copy, "file")).mode & 0o7777
      second_copy = File.join(root, "second")
      boundary.materialize(second, destination: second_copy)
      assert_equal 0o444, File.stat(File.join(second_copy, "file")).mode & 0o7777
      assert_empty legacy.fetch("metadata")
    end
  end

  def test_opt_in_modes_are_bound_without_changing_legacy_content
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "nested"))
      Dir.mkdir(File.join(source, "empty"))
      File.write(File.join(source, "nested", "readonly"), "fixture")
      File.chmod(0o444, File.join(source, "nested", "readonly"))
      File.write(File.join(source, "run"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(source, "run"))
      File.chmod(0o555, File.join(source, "nested"))
      File.chmod(0o750, source)
      store = AgentRuntime::Store.new(File.join(root, "store"))
      boundary = AgentRuntime::Benchmarks::Submission.new(store: store)
      legacy = boundary.capture(repository: source)
      exact = boundary.capture(repository: source, preserve_modes: true)
      assert_equal legacy.fetch("digest"), exact.fetch("digest")
      destination = File.join(root, "copy")
      boundary.materialize(exact, destination: destination)
      assert_equal 0o750, File.stat(destination).mode & 0o7777
      assert File.directory?(File.join(destination, "empty"))
      assert_equal 0o444, File.stat(File.join(destination, "nested", "readonly")).mode & 0o7777
      assert_equal 0o555, File.stat(File.join(destination, "nested")).mode & 0o7777
      assert_equal 0o755, File.stat(File.join(destination, "run")).mode & 0o7777
      working = File.join(root, "working")
      assert system("cp", "-R", destination, working)
      File.chmod(0o755, working)
      assert_equal 0o444, File.stat(File.join(working, "nested", "readonly")).mode & 0o7777
      assert_equal 0o555, File.stat(File.join(working, "nested")).mode & 0o7777
      forged = exact.merge("metadata" => {})
      assert boundary.verify_snapshot!(forged, destination)
      File.chmod(0o644, File.join(destination, "nested", "readonly"))
      assert_raises(AgentRuntime::Error) { boundary.verify_snapshot!(forged, destination) }
      assert boundary.verify(legacy)
      reference = exact.fetch("metadata").fetch("mode_evidence")
      sidecar_path = store.artifact(reference.fetch("id")).fetch("path")
      File.chmod(0o644, sidecar_path)
      File.write(sidecar_path, "{}")
      assert_raises(AgentRuntime::Error) { boundary.verify(exact) }
    ensure
      Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).each { |path| File.chmod(0o755, path) if File.directory?(path) }
    end
  end

  def test_special_permission_bits_are_rejected
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      File.write(File.join(source, "bad"), "fixture")
      File.chmod(0o4755, File.join(source, "bad"))
      boundary = AgentRuntime::Benchmarks::Submission.new(store: AgentRuntime::Store.new(File.join(root, "store")))
      assert_raises(AgentRuntime::Error) { boundary.capture(repository: source, preserve_modes: true) }
    end
  end
end
