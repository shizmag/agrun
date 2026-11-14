module AgentRuntime
  module Benchmarks
    # Store owns persistence; this boundary additionally rejects filesystem aliases.
    class Submission
      def initialize(store:)
        @store = store
      end

      def capture(repository:, run_id: "benchmark", step_id: "submission", attempt: 1)
        validate_tree!(repository)
        artifact = @store.put(type: "repository", value: repository, run_id: run_id, step_id: step_id, attempt: attempt)
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
        verify_snapshot!(stored, destination)
        destination
      end

      def verify_snapshot!(artifact, destination)
        validate_tree!(destination)
        actual = Digest::SHA256.hexdigest(IR.dump(Store.manifest(destination)))
        raise Error, "private submission snapshot changed" unless actual == artifact.fetch("digest")
        true
      end

      private

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
