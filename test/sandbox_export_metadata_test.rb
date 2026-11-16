require_relative "test_helper"
require_relative "../lib/agent_runtime/execution/sandbox_runner"
require "rubygems/package"
require "stringio"

class SandboxExportMetadataTest < Minitest::Test
  def test_real_docker_read_only_executable_export
    skip "explicit Docker export opt-in required" unless ENV["AGRU_S2_EXPORT_DOCKER"] == "1"
    image = ENV.fetch("AGRU_S2_EXPORT_IMAGE", "sha256:cbc8bd81c7ede30f09de318df230452f4d3a05e1e8aa9f08a4d46b7f24f437f1")
    in_tmp do |root|
      real = AgentRuntime::Execution::SandboxRunner.new(image: image,
        limits: {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216})
      result = real.call(argv: ["/bin/sh", "-c", "mkdir nested; printf '#!/bin/sh\\nexit 0\\n' > nested/run; chmod 555 nested/run nested"], workspace: root, timeout: 10)
      assert_equal "success", result["status"], result.inspect
      exported = result.fetch("export_directory")
      assert_equal 0o555, File.stat(File.join(exported, "nested", "run")).mode & 0o7777
      assert_equal 0o555, File.stat(File.join(exported, "nested")).mode & 0o7777
    ensure
      if exported
        File.chmod(0o755, File.join(exported, "nested")) if File.directory?(File.join(exported, "nested"))
        FileUtils.remove_entry(exported)
      end
    end
  end

  def runner(**limits)
    AgentRuntime::Execution::SandboxRunner.new(image: "alpine@sha256:#{"a" * 64}",
      limits: {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}.merge(limits.transform_keys(&:to_s)))
  end

  def archive(mode: 0o644, name: "file", contents: "data")
    bytes = StringIO.new("".b)
    Gem::Package::TarWriter.new(bytes) do |tar|
      tar.add_file_simple(name, mode, contents.bytesize) { |io| io.write(contents) }
    end
    bytes.string
  end

  def test_privileged_modes_are_rejected_not_silently_stripped
    [0o4644, 0o2644, 0o1644].each do |mode|
      in_tmp do |root|
        assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
          runner.send(:extract_archive!, archive(mode: mode), root)
        end
      end
      in_tmp do |root|
        source = File.join(root, "source")
        Dir.mkdir(source)
        File.write(File.join(source, "file"), "data")
        File.chmod(mode, File.join(source, "file"))
        assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
          runner.send(:copy_tree!, source, File.join(root, "copy"), timeout: 5, cancellation: nil)
        end
      end
    end
  end

  def test_archive_requires_complete_terminator_and_rejects_trailing_data
    valid = archive
    [valid.byteslice(0, 1024), valid.byteslice(0, 1536), valid + "unexpected", valid.byteslice(0, 513)].each do |bytes|
      in_tmp do |root|
        assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
          runner.send(:extract_archive!, StringIO.new(bytes), root)
        end
      end
    end
  end

  def test_archive_rejects_duplicate_paths_and_traversal
    [archive + archive, archive(name: "../outside"), archive(name: "/absolute"), archive(name: "a/./file")].each do |bytes|
      in_tmp do |root|
        assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
          runner.send(:extract_archive!, bytes, root)
        end
      end
    end
  end

  def test_shared_deadline_is_checked_during_copy_and_extraction
    deadline = Object.new
    deadline.define_singleton_method(:check!) { |phase:| raise AgentRuntime::Execution::SandboxRunner::BoundaryError, phase }
    in_tmp do |root|
      assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
        runner.send(:extract_archive!, archive, root, deadline: deadline)
      end
      assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
        runner.send(:copy_tree!, root, File.join(root, "copy"), timeout: 5, cancellation: nil, deadline: deadline)
      end
    end
  end

  def test_root_mode_and_implicit_parent_are_preserved_safely
    bytes = StringIO.new("".b)
    Gem::Package::TarWriter.new(bytes) do |tar|
      tar.mkdir("./", 0o555)
      tar.add_file_simple("missing/parent/file", 0o444, 1) { |io| io.write("x") }
    end
    in_tmp do |root|
      runner.send(:extract_archive!, StringIO.new(bytes.string), root)
      assert_equal "x", File.read(File.join(root, "missing/parent/file"))
      assert_equal 0o555, File.stat(root).mode & 0o7777
    ensure
      File.chmod(0o755, root)
    end
  end

  def test_export_manifest_and_digest_bind_all_ordinary_permission_bits
    in_tmp do |root|
      source = File.join(root, "source")
      Dir.mkdir(source, 0o755)
      Dir.mkdir(File.join(source, "nested"), 0o755)
      file = File.join(source, "nested", "file")
      File.write(file, "same bytes")
      File.chmod(0o644, file)
      manifests = []
      4.times do |index|
        manifests << runner.send(:copy_tree!, source, File.join(root, "copy#{index}"), timeout: 5, cancellation: nil)
        case index
        when 0 then File.chmod(0o444, file)
        when 1 then File.chmod(0o711, File.join(source, "nested"))
        when 2 then File.chmod(0o711, source)
        end
      end
      assert_equal 4, manifests.map { |manifest| Digest::SHA256.hexdigest(JSON.generate(manifest)) }.uniq.length
      assert_includes manifests[0], ["", "directory", 0o755]
      assert_includes manifests[0], ["nested", "directory", 0o755]
      assert_includes manifests[0], ["nested/file", "file", Digest::SHA256.hexdigest("same bytes"), 0o644]
      assert_includes manifests[1], ["nested/file", "file", Digest::SHA256.hexdigest("same bytes"), 0o444]
      assert_includes manifests[2], ["nested", "directory", 0o711]
      assert_includes manifests[3], ["", "directory", 0o711]
    end
  end

  def test_input_resource_caps_reject_before_any_docker_dispatch
    ["file", "directory"].each do |kind|
      in_tmp do |root|
        count = (kind == "directory") ? 1024 : 1025
        count.times do |index|
          path = File.join(root, "entry#{index}")
          (kind == "directory") ? Dir.mkdir(path) : File.write(path, "")
        end
        calls = []
        transport = Object.new
        transport.define_singleton_method(:call) { |**args|
          calls << args
          raise "Docker must not run"
        }
        boundary = AgentRuntime::Execution::SandboxRunner.new(image: "sha256:#{"a" * 64}",
          limits: {"cpus" => 1, "memory_bytes" => 134_217_728, "pids" => 32, "tmpfs_bytes" => 16_777_216}, process_runner: transport)
        result = boundary.call(argv: ["/bin/true"], workspace: root, timeout: 10)
        assert_equal "failure", result["status"]
        expected = (kind == "file") ? "input regular-file limit exceeded (1024)" : "input directory limit exceeded (1024)"
        assert_includes result.fetch("error"), expected
        assert_empty calls
      end
    end
  end

  def test_output_copy_is_not_restricted_to_input_file_descriptor_cap
    in_tmp do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      1025.times { |index| File.write(File.join(source, "file#{index}"), "") }
      manifest = runner.send(:copy_tree!, source, File.join(root, "export"), timeout: 10, cancellation: nil)
      assert_equal 1025, manifest.count { |entry| entry[1] == "file" }
    end
  end

  def test_special_archive_members_are_rejected
    %w[1 2 3 4 6].each do |type|
      header = Gem::Package::TarHeader.new(name: "special", mode: 0o644, size: 0, typeflag: type, linkname: "outside", prefix: "").to_s
      in_tmp do |root|
        assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
          runner.send(:extract_archive!, header + "\0" * 1024, root)
        end
        refute File.exist?(File.join(root, "special"))
      end
    end
  end

  def test_every_truncated_header_and_payload_is_rejected
    bytes = archive
    [0, 1, 100, 511, 512, 513, 515, 516, 1023, 1024, 1535, 1536, 2047].each do |length|
      in_tmp do |root|
        assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
          runner.send(:extract_archive!, StringIO.new(bytes.byteslice(0, length)), root)
        end
      end
    end
  end

  def test_deterministic_directory_symlink_swap_never_accepts_external_bytes
    in_tmp do |root|
      source = File.join(root, "source")
      external = File.join(root, "external")
      FileUtils.mkdir_p(File.join(source, "switch"))
      Dir.mkdir(external)
      File.write(File.join(external, "secret"), "external-canary")
      boundary = runner
      original = boundary.method(:descriptor_children)
      boundary.define_singleton_method(:descriptor_children) do |directory|
        names = original.call(directory)
        if names.include?("switch")
          File.rename(File.join(source, "switch"), File.join(source, "held"))
          File.symlink(external, File.join(source, "switch"))
        end
        names
      end
      destination = File.join(root, "copy")
      assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
        boundary.send(:copy_tree!, source, destination, timeout: 5, cancellation: nil)
      end
      refute File.exist?(File.join(destination, "switch", "secret"))
      assert_equal "external-canary", File.read(File.join(external, "secret"))
    end
  end

  def test_descriptor_copy_preserves_read_only_executable_and_directory_modes_without_privileged_bits
    in_tmp do |root|
      source = File.join(root, "source")
      Dir.mkdir(source)
      Dir.mkdir(File.join(source, "nested"))
      File.write(File.join(source, "nested", "run"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o555, File.join(source, "nested", "run"))
      File.chmod(0o555, File.join(source, "nested"))
      destination = File.join(root, "copy")
      runner.send(:copy_tree!, source, destination, timeout: 5, cancellation: nil)
      assert_equal 0o555, File.stat(File.join(destination, "nested", "run")).mode & 0o7777
      assert_equal 0o555, File.stat(File.join(destination, "nested")).mode & 0o7777
      assert_equal File.binread(File.join(source, "nested", "run")), File.binread(File.join(destination, "nested", "run"))
    ensure
      [source, destination].compact.each do |base|
        nested = File.join(base, "nested")
        File.chmod(0o755, nested) if File.directory?(nested)
      end
    end
  end

  def test_archive_preserves_directory_modes_after_populating_children
    bytes = StringIO.new("".b)
    Gem::Package::TarWriter.new(bytes) do |tar|
      tar.mkdir("nested", 0o555)
      tar.add_file_simple("nested/run", 0o555, 4) { |io| io.write("data") }
    end
    in_tmp do |root|
      runner.send(:extract_archive!, bytes.string, root)
      assert_equal "data", File.read(File.join(root, "nested", "run"))
      assert_equal 0o555, File.stat(File.join(root, "nested", "run")).mode & 0o7777
      assert_equal 0o555, File.stat(File.join(root, "nested")).mode & 0o7777
    ensure
      nested = File.join(root, "nested")
      File.chmod(0o755, nested) if File.directory?(nested)
    end
  end

  def test_archive_byte_limit_is_enforced_before_export_copy
    bytes = StringIO.new("".b)
    Gem::Package::TarWriter.new(bytes) do |tar|
      tar.add_file_simple("large", 0o644, 5) { |io| io.write("12345") }
    end
    in_tmp do |root|
      assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
        runner(workspace_bytes: 4).send(:extract_archive!, bytes.string, root)
      end
    end
  end

  def test_archive_entry_limit_is_enforced_before_export_copy
    bytes = StringIO.new("".b)
    Gem::Package::TarWriter.new(bytes) do |tar|
      tar.mkdir("one", 0o755)
      tar.mkdir("two", 0o755)
    end
    in_tmp do |root|
      assert_raises(AgentRuntime::Execution::SandboxRunner::BoundaryError) do
        runner(workspace_entries: 1).send(:extract_archive!, bytes.string, root)
      end
    end
  end
end
