module AgentRuntime
  module Benchmarks
    # Store owns persistence; this boundary additionally rejects filesystem aliases.
    class Submission
      def initialize(store:)
        @store = store
      end

      def capture(repository:, run_id: "benchmark", step_id: "submission", attempt: 1, preserve_modes: false)
        validate_tree!(repository)
        modes = mode_manifest(repository) if preserve_modes
        artifact = @store.put(type: "repository", value: repository, run_id: run_id, step_id: step_id, attempt: attempt)
        if modes
          raise Error, "submission modes changed during capture" unless mode_manifest(repository) == modes
          sidecar = @store.put(type: "json", value: {"schema" => "submission-modes-v1", "content_digest" => artifact.fetch("digest"), "entries" => modes}, run_id: run_id, step_id: step_id, attempt: attempt)
          artifact = @store.put(type: "repository", value: repository, run_id: run_id, step_id: step_id, attempt: attempt,
            metadata: {"mode_evidence" => sidecar.slice("id", "digest")})
          raise Error, "submission modes changed during capture" unless mode_manifest(repository) == modes
          raise Error, "submission content changed during mode capture" unless artifact.fetch("digest") == @store.value(sidecar).fetch("content_digest")
        end
        verify(artifact)
      end

      def verify(artifact)
        raise Error, "submission must be a repository artifact" unless artifact.is_a?(Hash) && artifact["type"] == "repository"
        stored = @store.artifact(artifact.fetch("id"))
        %w[id type digest path].each do |key|
          raise Error, "submission identity mismatch: #{key}" unless artifact.fetch(key) == stored.fetch(key)
        end
        validate_tree!(stored.fetch("path"))
        @store.value(stored)
        bound_modes(stored)
        stored
      rescue KeyError => e
        raise Error, "invalid submission: #{e.message}"
      end

      def materialize(artifact, destination:)
        stored = verify(artifact)
        raise Error, "snapshot destination already exists" if File.exist?(destination) || File.symlink?(destination)
        # Read the Store's verified manifest, never copy a mutable working tree.
        manifest = Store.manifest(stored.fetch("path"))
        raise Error, "submission changed before snapshot" unless Digest::SHA256.hexdigest(IR.dump(manifest)) == stored.fetch("digest")
        Store.materialize(manifest, destination)
        if (modes = bound_modes(stored))
          modes.each { |entry| FileUtils.mkdir_p(File.join(destination, entry.fetch("path"))) if entry.fetch("kind") == "directory" }
          modes.reverse_each do |entry|
            File.chmod(entry.fetch("mode"), File.join(destination, entry.fetch("path")))
          end
        end
        verify_snapshot!(stored, destination)
        destination
      end

      def verify_snapshot!(artifact, destination)
        artifact = verify(artifact)
        validate_tree!(destination)
        if (modes = bound_modes(artifact))
          raise Error, "submission snapshot modes changed" unless mode_manifest(destination) == modes
        end
        actual = Digest::SHA256.hexdigest(IR.dump(Store.manifest(destination)))
        raise Error, "private submission snapshot changed" unless actual == artifact.fetch("digest")
        true
      end

      private

      def mode_manifest(root)
        paths = ["."] + Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| (path.split("/") & [".", ".git"]).any? }.sort
        paths.map do |path|
          stat = File.lstat(File.join(root, path))
          mode = stat.mode & 0o7777
          raise Error, "special submission permission bits forbidden" unless (mode & 0o7000).zero?
          {"path" => path, "kind" => stat.directory? ? "directory" : "file", "mode" => mode}
        end
      end

      def bound_modes(artifact)
        reference = artifact.fetch("metadata")["mode_evidence"]
        return unless reference
        sidecar = @store.artifact(reference.fetch("id"))
        raise Error, "submission mode evidence identity mismatch" unless sidecar.fetch("digest") == reference.fetch("digest") && sidecar.fetch("type") == "json"
        evidence = @store.value(sidecar)
        raise Error, "submission mode evidence binding mismatch" unless evidence.fetch("schema") == "submission-modes-v1" && evidence.fetch("content_digest") == artifact.fetch("digest")
        entries = evidence.fetch("entries")
        expected = mode_manifest(artifact.fetch("path")).map { |entry| entry.slice("path", "kind") }
        valid = entries.is_a?(Array) && entries.all? { |entry| entry.keys.sort == %w[kind mode path] && entry["mode"].is_a?(Integer) && entry["mode"].between?(0, 0o777) && %w[file directory].include?(entry["kind"]) && entry["path"].is_a?(String) && (entry["path"] == "." || (!entry["path"].start_with?("/") && entry["path"].split("/", -1).none? { |part| ["", ".", "..", ".git"].include?(part) })) }
        if valid
          shapes = entries.map { |entry| entry.slice("path", "kind") }
          valid &&= shapes.uniq == shapes && (expected - shapes).empty? && (shapes - expected).all? { |entry| entry["kind"] == "directory" }
        end
        raise Error, "invalid submission mode manifest" unless valid
        entries
      end

      def validate_tree!(root)
        stat = File.lstat(root)
        raise Error, "submission root must be a real directory" unless stat.directory? && !stat.symlink?
        Dir.children(root).each do |name|
          raise Error, "unsafe submission path" if [".", ".."].include?(name) || name.include?("/") || name.include?("\0") || name.include?("\\")
          path = File.join(root, name)
          entry = File.lstat(path)
          raise Error, "symlinks and special submission files are forbidden" unless entry.file? || entry.directory?
          raise Error, "hard-linked submission files are forbidden" if entry.file? && entry.nlink != 1
          validate_tree!(path) if entry.directory?
        end
      rescue SystemCallError => e
        raise Error, "invalid submission tree: #{e.message}"
      end
    end
  end
end
