require "sqlite3"

module AgentRuntime
  class Store
    attr_reader :root
    attr_accessor :tracing

    def initialize(root)
      @root = File.expand_path(root)
      FileUtils.mkdir_p(File.join(@root, "objects"))
      @mutex = Mutex.new
      @db = SQLite3::Database.new(File.join(@root, "metadata.sqlite3"))
      @db.busy_timeout = 5000
      @db.execute_batch(<<~SQL)
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS artifacts(id TEXT PRIMARY KEY, digest TEXT NOT NULL, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS attempts(run_id TEXT, step_id TEXT, attempt INTEGER, data TEXT NOT NULL, PRIMARY KEY(run_id,step_id,attempt));
      SQL
    end

    def put(type:, value:, run_id:, step_id:, attempt:, inputs: [], metadata: {})
      type = type.to_s
      Compiler.type!(type)
      validate_value!(type, value)
      bytes = case type
      when "repository", "directory" then IR.dump(self.class.manifest(value))
      when "file" then File.binread(value)
      when "text", "string", "patch" then value.b
      else IR.dump(value)
      end
      digest = Digest::SHA256.hexdigest(bytes)
      # Reuse must not repair damaged historical evidence. New content still
      # creates its first object normally; equal bytes retain distinct IDs.
      existing = @mutex.synchronize { @db.execute("SELECT id FROM artifacts WHERE digest = ?", [digest]) }
      existing.each { |row| value(artifact(row.fetch(0))) }
      @mutex.synchronize do
        object = File.join(root, "objects", digest)
        unless File.exist?(object)
          File.binwrite(object, bytes)
          File.chmod(0o444, object)
        end
        path = object
        if %w[repository directory].include?(type)
          path = "#{object}.tree"
          unless Dir.exist?(path)
            self.class.materialize(JSON.parse(bytes), path)
            Dir.glob("#{path}/**/*", File::FNM_DOTMATCH).reject { |p| File.basename(p) == "." }.reverse_each { |p|
              mode = File.executable?(p) ? 0o555 : 0o444
              mode = 0o755 if File.directory?(p)
              File.chmod(mode, p)
            }
          end
        end
        artifact = {"id" => SecureRandom.uuid, "digest" => digest, "type" => type, "path" => path, "run_id" => run_id, "step_id" => step_id, "attempt" => attempt, "inputs" => inputs, "created_at" => Time.now.utc.iso8601(6), "metadata" => metadata}
        @db.execute("INSERT INTO artifacts VALUES(?,?,?)", [artifact["id"], digest, JSON.generate(artifact)])
        artifact
      end
    end

    def artifact(id)
      row = @mutex.synchronize { @db.get_first_row("SELECT digest,data FROM artifacts WHERE id=?", [id]) }
      raise Error, "unknown artifact #{id}" unless row
      record = JSON.parse(row[1])
      valid = record.is_a?(Hash) && record["id"] == id && record["digest"] == row[0] &&
        %w[id digest type path run_id step_id created_at].all? { |key| record[key].is_a?(String) && !record[key].empty? } &&
        record["digest"].match?(/\A[0-9a-f]{64}\z/) && record["attempt"].is_a?(Integer) &&
        record["inputs"].is_a?(Array) && record["metadata"].is_a?(Hash)
      raise Error, "invalid canonical artifact #{id}" unless valid
      Compiler.type!(record["type"])
      record
    rescue => error
      raise error if error.is_a?(Error)
      raise Error, "artifact metadata read failed: #{error.class}: #{error.message}"
    end

    def value(artifact)
      bytes = validated_bytes(artifact, {})
      type = artifact.fetch("type")
      path = artifact.fetch("path")
      case type
      when "repository", "directory", "file" then path
      when "text", "string", "patch" then bytes.force_encoding(Encoding::UTF_8)
      else JSON.parse(bytes)
      end
    rescue => error
      raise error if error.is_a?(Error)
      raise Error, "artifact read failed: #{error.class}: #{error.message}"
    end

    def save_report(report)
      @mutex.synchronize { @db.execute("INSERT OR REPLACE INTO runs VALUES(?,?)", [report.fetch("run_id"), JSON.generate(report)]) }
      report
    end

    def report(run_id)
      row = @mutex.synchronize { @db.get_first_value("SELECT data FROM runs WHERE id=?", [run_id]) }
      raise Error, "unknown run #{run_id}" unless row
      JSON.parse(row)
    end

    def save_attempt(run_id, step_id, attempt, data)
      @mutex.synchronize { @db.execute("INSERT OR REPLACE INTO attempts VALUES(?,?,?,?)", [run_id, step_id, attempt, JSON.generate(data)]) }
    end

    def self.manifest(directory)
      root = File.realpath(directory)
      Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).sort.filter_map do |path|
        relative = path.delete_prefix("#{root}/")
        next if relative.split("/").include?(".git") || relative == "."
        raise Error, "symlinks are unsupported in M0 snapshots: #{relative}" if File.symlink?(path)
        next if File.directory?(path)
        raise Error, "unsupported snapshot entry #{relative}" unless File.file?(path)
        {"path" => relative, "executable" => File.executable?(path), "content" => [File.binread(path)].pack("m0")}
      end
    end

    def self.materialize(manifest, directory)
      FileUtils.mkdir_p(directory)
      manifest.each do |entry|
        relative = entry.fetch("path")
        raise Error, "unsafe snapshot path" if relative.start_with?("/") || relative.split("/").any? { |p| ["..", ".git"].include?(p) }
        path = File.join(directory, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, entry.fetch("content").unpack1("m0"))
        File.chmod(entry["executable"] ? 0o755 : 0o644, path)
      end
    end

    private

    def validated_bytes(record, visiting)
      raise Error, "invalid artifact reference" unless record.is_a?(Hash)
      canonical = artifact(record.fetch("id"))
      raise Error, "artifact metadata integrity violation #{canonical["id"]}" unless record == canonical
      id = canonical.fetch("id")
      raise Error, "cyclic artifact provenance #{id}" if visiting[id]
      visiting[id] = true
      canonical.fetch("inputs").each do |input|
        validated_bytes(input.is_a?(String) ? artifact(input) : input, visiting)
      end
      object = File.join(root, "objects", canonical.fetch("digest"))
      tree = %w[repository directory].include?(canonical.fetch("type"))
      expected_path = tree ? "#{object}.tree" : object
      raise Error, "invalid artifact path #{id}" unless canonical.fetch("path") == expected_path
      raise Error, "invalid artifact object #{id}" unless File.file?(object) && !File.symlink?(object)
      bytes = File.binread(object)
      raise Error, "artifact content integrity violation #{id}" unless Digest::SHA256.hexdigest(bytes) == canonical.fetch("digest")
      if tree
        raise Error, "invalid artifact tree #{id}" unless File.directory?(expected_path) && !File.symlink?(expected_path)
        manifest = IR.dump(self.class.manifest(expected_path))
        raise Error, "artifact tree integrity violation #{id}" unless manifest == bytes
      end
      visiting.delete(id)
      bytes
    end

    def validate_value!(type, value)
      valid = case type
      when "text", "string", "patch" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric) && value.finite?
      when "boolean" then value == true || value == false
      when "file" then value.is_a?(String) && File.file?(value) && !File.symlink?(value)
      when "repository", "directory" then value.is_a?(String) && File.directory?(value)
      when "evaluation_report"
        value.is_a?(Hash) && (%w[artifact specification procedure environment] - value.keys).empty?
      else true
      end
      raise Error, "invalid runtime value for #{type}" unless valid
    end
  end
end
