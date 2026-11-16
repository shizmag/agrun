require "digest"
require "json"
require "open3"

module AgentRuntime
  module Benchmarks
    # Content identity includes uncommitted implementation bytes: a Git revision
    # alone cannot freeze an experiment assembled from a working tree.
    module ReleaseIdentity
      module_function

      def capture(root:)
        root = File.expand_path(root)
        paths = %w[lib programs models sandbox integrations benchmarks].flat_map do |directory|
          Dir.glob(File.join(root, directory, "**", "*"), File::FNM_DOTMATCH)
        end
        paths += %w[Gemfile Gemfile.lock mise.toml CONTRACTS.md].map { |name| File.join(root, name) }
        files = paths.select { |path| File.file?(path) && !File.symlink?(path) && !path.include?("/.git/") }.sort.to_h do |path|
          [path.delete_prefix("#{root}/"), Digest::SHA256.file(path).hexdigest]
        end
        revision, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
        raise ArgumentError, "cannot resolve runtime revision" unless status.success?
        payload = {"schema_version" => "agru-release-content-v1", "git_revision" => revision.strip, "files" => files}
        payload.merge("content_digest" => Digest::SHA256.hexdigest(JSON.generate(files)))
      end

      def verify!(identity, root:)
        raise ArgumentError, "unsupported release identity" unless identity.fetch("schema_version") == "agru-release-content-v1"
        files = identity.fetch("files")
        raise ArgumentError, "release identity digest mismatch" unless Digest::SHA256.hexdigest(JSON.generate(files)) == identity.fetch("content_digest")
        raise ArgumentError, "release file inventory mismatch" unless capture(root: root).fetch("files").keys == files.keys
        files.each do |path, digest|
          full = File.expand_path(path, root)
          raise ArgumentError, "unsafe release path" unless full.start_with?("#{File.expand_path(root)}/") && !File.symlink?(full)
          raise ArgumentError, "release file missing or changed: #{path}" unless File.file?(full) && Digest::SHA256.file(full).hexdigest == digest
        end
        true
      end
    end
  end
end
