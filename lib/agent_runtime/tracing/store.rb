require "sqlite3"
require "json"
require "digest"
require "zlib"
require "securerandom"
require "fileutils"
require "time"

module AgentRuntime
  module Tracing
    # Local evidence storage, not an authenticity or process-isolation boundary.
    class Store
      VERSION = 2
      FILTERS = %w[experiment cell experiment_id cell_id run_id architecture stage attempt request tool].freeze
      SECRET = /authorization|credential|password|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|cookie/i
      attr_reader :root

      def initialize(root, raw_content: false)
        @root = File.expand_path(root)
        @raw_content = raw_content
        @mutex = Mutex.new
        @clocks = {}
        FileUtils.mkdir_p(File.join(@root, "blobs"), mode: 0o700)
        File.chmod(0o700, @root, File.join(@root, "blobs"))
        database_path = File.join(@root, "trace.sqlite3")
        File.open(database_path, File::RDWR | File::CREAT, 0o600) { |file| file.chmod(0o600) }
        @db = SQLite3::Database.new(database_path)
        @db.results_as_hash = true
        @db.busy_timeout = 5000
        @db.execute("PRAGMA journal_mode=WAL")
        @db.execute("PRAGMA synchronous=FULL")
        @db.transaction(:immediate) do
          version = @db.get_first_value("PRAGMA user_version")
          raise ArgumentError, "unsupported trace schema #{version}" if version > VERSION
          @db.execute("CREATE TABLE IF NOT EXISTS entities (id TEXT PRIMARY KEY, kind TEXT NOT NULL, parent_id TEXT, status TEXT NOT NULL, started_at TEXT NOT NULL, finished_at TEXT, duration REAL, attributes TEXT NOT NULL, provenance TEXT NOT NULL)")
          %w[kind parent_id status].each { |key| @db.execute("CREATE INDEX IF NOT EXISTS entities_#{key} ON entities(#{key})") }
          FILTERS.each { |key| @db.execute("CREATE INDEX IF NOT EXISTS entities_attr_#{key} ON entities(json_extract(attributes, '$.#{key}'))") }
          @db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
          (1..VERSION).each { |migration| @db.execute("INSERT OR IGNORE INTO schema_migrations VALUES (?,?)", [migration, Time.now.utc.iso8601(6)]) }
          @db.execute("CREATE TABLE IF NOT EXISTS incidents (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, entity_id TEXT, recorded_at TEXT NOT NULL, details TEXT NOT NULL)")
          @db.execute("CREATE INDEX IF NOT EXISTS incidents_entity ON incidents(entity_id)")
          @db.execute("PRAGMA user_version=#{VERSION}")
        end
        secure_files
      end

      def start(kind:, parent_id: nil, id: nil, attributes: {}, provenance: {})
        id = (id || SecureRandom.uuid).to_s
        raise ArgumentError, "empty trace identity" if id.empty?
        failure = nil
        @mutex.synchronize do
          @db.transaction(:immediate) do
            if @db.get_first_value("SELECT 1 FROM entities WHERE id=?", [id])
              record_incident("duplicate_start", id)
              failure = SQLite3::ConstraintException.new("duplicate trace #{id}")
            else
              parent = parent_id && @db.get_first_row("SELECT * FROM entities WHERE id=?", [parent_id.to_s])
              inherited = parent ? JSON.parse(parent["attributes"]).slice(*FILTERS) : {}
              if parent_id && !parent
                record_incident("out_of_order_start", id, {"parent_id" => parent_id.to_s})
              elsif parent && parent["status"] != "running"
                record_incident("parent_already_finished", id, {"parent_id" => parent_id.to_s})
              end
              merged = inherited.merge(redact(attributes))
              @db.execute("INSERT INTO entities(id,kind,parent_id,status,started_at,attributes,provenance) VALUES(?,?,?,?,?,?,?)", [id, kind.to_s, parent_id&.to_s, "running", Time.now.utc.iso8601(6), JSON.generate(merged), JSON.generate(redact(provenance))])
              @clocks[id] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
          secure_files
        end
        raise failure if failure
        id
      end

      def finish(id, status:, attributes: {})
        raise ArgumentError, "terminal status required" if status.to_s.empty? || status.to_s == "running"
        failure = nil
        @mutex.synchronize do
          @db.transaction(:immediate) do
            row = @db.get_first_row("SELECT * FROM entities WHERE id=?", [id.to_s])
            if !row || row["status"] != "running"
              record_incident(row ? "duplicate_finish" : "out_of_order_finish", id.to_s)
              failure = ArgumentError.new(row ? "trace already finished #{id}" : "unknown trace #{id}")
            else
              clock = @clocks[id.to_s]
              duration = clock && Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock
              merged = JSON.parse(row["attributes"]).merge(redact(attributes))
              @db.execute("UPDATE entities SET status=?,finished_at=?,duration=?,attributes=? WHERE id=?", [status.to_s, Time.now.utc.iso8601(6), duration, JSON.generate(merged), id.to_s])
            end
          end
          @clocks.delete(id.to_s) unless failure
        end
        raise failure if failure
        get(id)
      end

      def event(kind:, parent_id:, attributes: {}, id: nil)
        identity = start(kind: kind, parent_id: parent_id, attributes: attributes, id: id)
        finish(identity, status: "success")
        identity
      end

      # Raw allows sensitive content, but credential-key redaction is mandatory in both modes.
      def payload(value, raw: false)
        raise ArgumentError, "raw content disabled" if raw && !@raw_content
        bytes = JSON.generate(redact(value))
        digest = Digest::SHA256.hexdigest(bytes)
        @mutex.synchronize do
          path = blob_path(digest, raw)
          if File.exist?(path)
            raise IOError, "corrupt blob #{digest}" unless Digest::SHA256.hexdigest(Zlib::Inflate.inflate(File.binread(path))) == digest
          else
            temporary = "#{path}.#{SecureRandom.hex(8)}"
            begin
              File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file|
                file.write(Zlib::Deflate.deflate(bytes))
                file.flush
                file.fsync
              }
              File.rename(temporary, path)
            ensure
              FileUtils.rm_f(temporary)
            end
          end
        end
        {"digest" => digest, "raw" => raw, "encoding" => "json+zlib", "bytes" => bytes.bytesize}
      end

      def read_payload(reference, raw: false)
        ref = reference.transform_keys(&:to_s)
        raise ArgumentError, "payload omitted" if ref["omitted"]
        raise ArgumentError, "raw content disabled" if ref["raw"] && !(raw && @raw_content)
        bytes = @mutex.synchronize { Zlib::Inflate.inflate(File.binread(blob_path(ref.fetch("digest"), ref["raw"]))) }
        raise IOError, "corrupt payload" unless Digest::SHA256.hexdigest(bytes) == ref["digest"]
        JSON.parse(bytes)
      end

      def entities(filters = {})
        select_entities(filters)
      end

      # Uses indexed filters first; literal case-insensitive substring search, not SQL syntax.
      def search(query, filters: {})
        select_entities(filters, query: query.to_s)
      end

      def select_entities(filters, query: nil)
        conditions = []
        values = []
        filters.each do |key, value|
          key = key.to_s
          column = if %w[kind parent_id status].include?(key)
            key
          elsif FILTERS.include?(key)
            "json_extract(attributes, '$.#{key}')"
          else
            raise ArgumentError, "unknown trace filter #{key}"
          end
          conditions << "#{column} IS ?"
          values << value
        end
        unless query.nil?
          conditions << "instr(lower(attributes), lower(?)) > 0"
          values << query
        end
        sql = "SELECT * FROM entities"
        sql += " WHERE #{conditions.join(" AND ")}" unless conditions.empty?
        @mutex.synchronize { @db.execute(sql + " ORDER BY started_at,id", values).map { |row| decode(row) } }
      end

      private :select_entities

      def get(id)
        @mutex.synchronize do
          row = @db.get_first_row("SELECT * FROM entities WHERE id=?", [id.to_s])
          row && decode(row)
        end
      end

      def verify
        rows = entities
        ids = rows.to_h { |row| [row["id"], row] }
        errors = []
        incomplete = []
        @mutex.synchronize { errors << "sqlite_integrity" unless @db.get_first_value("PRAGMA integrity_check") == "ok" }
        Dir.glob(File.join(root, "blobs", "*.zlib")).each do |path|
          digest = File.basename(path).delete_prefix("raw-").delete_suffix(".zlib")
          begin
            bytes = Zlib::Inflate.inflate(File.binread(path))
            errors << "blob_digest:#{digest}" unless Digest::SHA256.hexdigest(bytes) == digest
          rescue
            errors << "corrupt_blob:#{digest}"
          end
        end
        incidents.each { |incident| incomplete << "incident:#{incident["kind"]}:#{incident["entity_id"]}" }
        rows.each do |row|
          id = row["id"]
          incomplete << "running:#{id}" if row["status"] == "running"
          errors << "missing_parent:#{id}" if row["parent_id"] && !ids.key?(row["parent_id"])
          parent_row = ids[row["parent_id"]]
          if parent_row && (row["started_at"] < parent_row["started_at"] || (parent_row["finished_at"] && (row["started_at"] > parent_row["finished_at"] || (row["finished_at"] && row["finished_at"] > parent_row["finished_at"]))))
            errors << "parent_timestamp_order:#{id}"
          end
          seen = {id => true}
          parent = row["parent_id"]
          while parent && ids[parent]
            if seen[parent]
              errors << "parent_cycle:#{id}"
              break
            end
            seen[parent] = true
            parent = ids[parent]["parent_id"]
          end
          walk(row) do |value|
            next unless value.is_a?(Hash) && value["encoding"] == "json+zlib"
            if value["omitted"] == true
              errors << "invalid_payload_omission:#{id}" unless value["raw"] == true
              incomplete << "snapshot_unavailable:#{id}" if row["kind"].match?(/checkpoint|artifact/)
              next
            end
            begin
              bytes = Zlib::Inflate.inflate(File.binread(blob_path(value.fetch("digest"), value["raw"])))
              errors << "blob_digest:#{id}" unless Digest::SHA256.hexdigest(bytes) == value["digest"]
            rescue
              errors << "missing_or_corrupt_blob:#{id}"
            end
          end
          attrs = row["attributes"]
          incomplete << "accounting_incomplete:#{id}" if attrs["accounting_complete"] == false
          incomplete << "evidence_unresolved:#{id}" if attrs["evidence_resolution"] == "not_resolved"
          incomplete << "unknown_status:#{id}" if %w[unknown incomplete interrupted].include?(row["status"])
          incomplete << "capture_gap:#{id}" if row["kind"] == "capture_gap" || attrs["capture_gap"] || attrs["capture_complete"] == false
          incomplete << "unknown_error:#{id}" if attrs["error"] == "unknown" || attrs["error_unknown"] == true || (attrs["error"].is_a?(Hash) && attrs["error"].value?("unknown"))
          incomplete << "interrupted:#{id}" if attrs["recovered_from_running"]
          planned = attrs["planned_stages"] || attrs["planned_steps"]
          if planned.is_a?(Array)
            actual = rows.select { |other| other["parent_id"] == id }.map { |other| other["attributes"]["stage"] || other["attributes"]["step"] || (%w[stage step].include?(other["kind"]) && other["attributes"]["name"]) }.compact
            (planned.map { |stage| stage.is_a?(Hash) ? stage["id"].to_s : stage.to_s } - actual.map(&:to_s)).each { |stage| incomplete << "missing_stage:#{id}:#{stage}" }
          end
          if row["kind"].match?(/checkpoint|artifact/) && (attrs["snapshot_available"] == false || attrs["snapshot_unavailable"] == true || (row["kind"] == "checkpoint" && attrs["artifact"] && !attrs["snapshot"]))
            incomplete << "snapshot_unavailable:#{id}"
          end
          if row["kind"].match?(/llm|provider|model_request/)
            usage = attrs["usage"]
            incomplete << "unknown_usage:#{id}" if usage.nil? || usage == "unknown" || (usage.is_a?(Hash) && (usage.empty? || usage.values.any? { |value| value.nil? || value == "unknown" }))
            if row["kind"] == "llm_request"
              incomplete << "response_incomplete:#{id}" unless attrs["response_complete"] == true
              incomplete << "request_incomplete:#{id}" unless attrs["complete"] == true
              incomplete << "request_identity_unknown:#{id}" unless attrs["provider_request_id"] || attrs["request_id"] || attrs["request"]
              incomplete << "usage_uncorrelated:#{id}" if attrs["usage_correlated"] == false || attrs["usage_correlation"] == "unknown" || (attrs["usage_request_id"] && attrs["usage_request_id"] != (attrs["provider_request_id"] || attrs["request_id"] || attrs["request"]))
            end
            incomplete << "stream_incomplete:#{id}" if attrs["stream_complete"] == false || attrs["stream_incomplete"] == true || (attrs["streaming"] == true && attrs["stream_complete"] != true)
          end
          if row["kind"].match?(/request[_.]start/)
            paired = rows.any? { |other| other["kind"].match?(/request[_.](finish|end)/) && (other["parent_id"] == id || (attrs["request"] && other["attributes"]["request"] == attrs["request"])) }
            incomplete << "unpaired_request:#{id}" unless paired
          end
        end
        {"valid" => errors.empty?, "complete" => errors.empty? && incomplete.empty?, "errors" => errors.uniq, "incomplete" => incomplete.uniq, "entity_count" => rows.length}
      end

      def export(destination, include_raw: false)
        destination = File.expand_path(destination)
        raise ArgumentError, "export destination exists" if File.exist?(destination)
        raise ArgumentError, "raw content disabled" if include_raw && !@raw_content
        FileUtils.mkdir_p(destination, mode: 0o700)
        FileUtils.mkdir_p(File.join(destination, "blobs"), mode: 0o700)
        @mutex.synchronize do
          @db.execute("VACUUM INTO ?", [File.join(destination, "trace.sqlite3")])
          Dir.glob(File.join(root, "blobs", "*.zlib")).each do |path|
            next if !include_raw && File.basename(path).start_with?("raw-")
            FileUtils.cp(path, File.join(destination, "blobs"))
          end
        end
        snapshot = self.class.new(destination)
        unless include_raw
          snapshot.send(:omit_raw_references)
        end
        report = snapshot.verify
        snapshot.close
        raise IOError, "invalid trace export: #{report["errors"].join(",")}" unless report["valid"]
        files = Dir.glob(File.join(destination, "**", "*")).select { |path| File.file?(path) }
        manifest = files.to_h { |path| [path.delete_prefix(destination + "/"), Digest::SHA256.file(path).hexdigest] }
        File.write(File.join(destination, "manifest.json"), JSON.generate({"version" => VERSION, "files" => manifest, "verification" => report}), mode: "w", perm: 0o600)
        files.each { |path| File.chmod(0o600, path) }
        destination
      end

      def self.import(source, destination)
        source = File.expand_path(source)
        manifest = JSON.parse(File.read(File.join(source, "manifest.json")))
        raise IOError, "unsupported archive" unless (1..VERSION).cover?(manifest["version"])
        files = manifest.fetch("files")
        raise IOError, "missing database" unless files.key?("trace.sqlite3")
        files.each do |name, digest|
          raise IOError, "unsafe archive path" unless name == "trace.sqlite3" || name.match?(/\Ablobs\/(raw-)?[a-f0-9]{64}\.zlib\z/)
          path = File.join(source, name)
          raise IOError, "unsafe archive directory" if name.start_with?("blobs/") && File.symlink?(File.join(source, "blobs"))
          raise IOError, "archive integrity failure: #{name}" if File.symlink?(path) || !File.file?(path) || Digest::SHA256.file(path).hexdigest != digest
        end
        raise ArgumentError, "import destination exists" if File.exist?(destination)
        FileUtils.mkdir_p(destination, mode: 0o700)
        files.each do |name, _|
          path = File.join(destination, name)
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          FileUtils.cp(File.join(source, name), path)
          File.chmod(0o600, path)
        end
        store = new(destination)
        unless store.verify["valid"]
          store.close
          raise IOError, "invalid imported trace"
        end
        store
      end

      def incidents
        @mutex.synchronize do
          @db.execute("SELECT * FROM incidents ORDER BY sequence").map { |row| row.merge("details" => JSON.parse(row["details"])) }
        end
      end

      # Explicit recovery never fabricates success or a cross-process monotonic duration.
      def recover
        entities(status: "running").map do |row|
          finish(row["id"], status: "unknown", attributes: {"recovered_from_running" => true})
        rescue ArgumentError
          get(row["id"])
        end
      end

      def close
        @mutex.synchronize { @db.close unless @db.closed? }
      end

      private

      def record_incident(kind, id, details = {})
        @db.execute("INSERT INTO incidents(kind,entity_id,recorded_at,details) VALUES(?,?,?,?)", [kind, id, Time.now.utc.iso8601(6), JSON.generate(redact(details))])
      end

      def redact(value)
        case value
        when Hash
          value.to_h { |key, item| [key.to_s, SECRET.match?(key.to_s) ? "[REDACTED]" : redact(item)] }
        when Array
          value.map { |item| redact(item) }
        else
          value
        end
      end

      def walk(value, &block)
        yield value
        case value
        when Hash then value.each_value { |item| walk(item, &block) }
        when Array then value.each { |item| walk(item, &block) }
        end
      end

      def omit_raw_references
        @mutex.synchronize do
          @db.execute("SELECT id,attributes,provenance FROM entities").each do |row|
            values = %w[attributes provenance].map do |key|
              value = JSON.parse(row[key])
              walk(value) { |item| item["omitted"] = true if item.is_a?(Hash) && item["encoding"] == "json+zlib" && item["raw"] }
              JSON.generate(value)
            end
            @db.execute("UPDATE entities SET attributes=?,provenance=? WHERE id=?", values + [row["id"]])
          end
        end
      end

      def decode(row)
        row.merge("attributes" => JSON.parse(row["attributes"]), "provenance" => JSON.parse(row["provenance"]))
      end

      def blob_path(digest, raw)
        raise ArgumentError, "invalid blob digest" unless digest.is_a?(String) && digest.match?(/\A[a-f0-9]{64}\z/)
        File.join(root, "blobs", "#{"raw-" if raw}#{digest}.zlib")
      end

      def secure_files
        Dir.glob(File.join(root, "trace.sqlite3*")).each { |path| File.chmod(0o600, path) }
      end
    end
  end
end
