require "json"
require "digest"

module AgentRuntime
  module Benchmarks
    # Validates evidence, never grants score or result authority.
    class AuditedResults
      SOURCE_PATH = File.expand_path(__FILE__).freeze
      SOURCE_SHA256 = Digest::SHA256.file(SOURCE_PATH).hexdigest.freeze
      MAX_BYTES = 4 * 1024 * 1024
      OUTCOMES = %w[passed failed error skipped xfailed xpassed].freeze
      FIELDS = %w[schema pytest_version binding collected collection_errors tests exit_code finished].freeze

      class Invalid < StandardError; end

      class UniqueObject < Hash
        def []=(key, value)
          raise Invalid, "duplicate JSON key" if key?(key)
          super
        end
      end

      def self.parse(bytes:, expected_nodeids:, expected_binding:, process:)
        new.parse(bytes: bytes, expected_nodeids: expected_nodeids, expected_binding: expected_binding, process: process)
      end

      def parse(bytes:, expected_nodeids:, expected_binding:, process:)
        check(bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES, "invalid result size")
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        check(text.valid_encoding?, "invalid result encoding")
        doc = JSON.parse(text, object_class: UniqueObject)
        keys(doc, FIELDS)
        check(doc["schema"] == "agru.pytest-results.v1" && doc["pytest_version"] == "8.4.1", "unsupported collector schema or runtime")
        check(expected_binding.is_a?(Hash) && !expected_binding.empty? && doc["binding"] == expected_binding, "binding mismatch")
        check(doc["finished"] == true, "unfinished session")
        identities(expected_nodeids, nonempty: true)
        identities(doc["collected"])
        check((doc["collected"] - expected_nodeids).empty?, "unexpected collection identity")
        check(doc["tests"].is_a?(Array) && doc["collection_errors"].is_a?(Array), "invalid report arrays")
        check(process.is_a?(Hash) && process["stdout_truncated"] == false && process["stderr_truncated"] == false, "truncated or incomplete transport")
        code = doc["exit_code"]
        check(code.is_a?(Integer) && process["exit_code"].is_a?(Integer) && code == process["exit_code"], "exit code mismatch")
        check(process["status"] == ((code == 0) ? "success" : "failure"), "process status mismatch")
        tests = {}
        doc["tests"].each do |test|
          keys(test, %w[nodeid reports])
          id = test["nodeid"]
          check(doc["collected"].include?(id) && !tests.key?(id), "unexpected or duplicate test identity")
          tests[id] = outcome(test["reports"])
        end
        unless doc["collection_errors"].empty?
          check([1, 2].include?(code), "invalid collection exit code")
          validate_collection_errors(doc["collection_errors"])
          return {"status" => "collection_failure", "collection_errors" => plain(doc["collection_errors"]),
                  "collected" => doc["collected"].dup}
        end
        check(doc["collected"].sort == expected_nodeids.sort && tests.keys.sort == expected_nodeids.sort, "incomplete test identity")
        counts = OUTCOMES.to_h { |name| [name, tests.values.count(name)] }
        check(code == ((counts["failed"] + counts["error"] > 0) ? 1 : 0), "exit code contradicts reports")
        executed = doc["tests"].count { |test| test["reports"].any? { |report| report["when"] == "call" } }
        {"status" => "valid", "tests" => tests, "counts" => counts, "executed" => executed}
      rescue Invalid, JSON::ParserError => e
        {"status" => "invalid", "reason" => e.message}
      end

      private

      def check(condition, reason)
        raise Invalid, reason unless condition
      end

      def keys(object, required, optional = [])
        check(object.is_a?(Hash) && (required - object.keys).empty? && (object.keys - required - optional).empty?, "invalid object fields")
      end

      def string(value)
        check(value.is_a?(String) && !value.empty? && !value.include?("\0"), "invalid string")
      end

      def identities(values, nonempty: false)
        check(values.is_a?(Array) && (!nonempty || !values.empty?), "invalid identity list")
        values.each { |id| string(id) }
        check(values.uniq.length == values.length, "duplicate collection identity")
      end

      def outcome(reports)
        check(reports.is_a?(Array), "invalid phase reports")
        reports.each do |report|
          keys(report, %w[when outcome], %w[wasxfail])
          check(%w[setup call teardown].include?(report["when"]) && %w[passed failed skipped].include?(report["outcome"]), "unknown phase or outcome")
          if report.key?("wasxfail")
            string(report["wasxfail"])
            check(report["outcome"] == "skipped" || (report["when"] == "call" && report["outcome"] == "passed"), "invalid xfail marker")
          end
        end
        phases = reports.map { |report| report["when"] }
        check(phases == %w[setup call teardown] || phases == %w[setup teardown], "incomplete or duplicate phases")
        setup = reports.first
        check((setup["outcome"] == "passed") == (phases.length == 3), "call contradicts setup")
        fixtures = [setup, reports.last]
        return "error" if fixtures.any? { |report| report["outcome"] == "failed" }
        skipped = fixtures.find { |report| report["outcome"] == "skipped" }
        return skipped.key?("wasxfail") ? "xfailed" : "skipped" if skipped
        call = reports[1]
        return "failed" if call["outcome"] == "failed"
        return call.key?("wasxfail") ? "xfailed" : "skipped" if call["outcome"] == "skipped"
        call.key?("wasxfail") ? "xpassed" : "passed"
      end

      def validate_collection_errors(errors)
        seen = []
        errors.each do |error|
          keys(error, %w[nodeid exception])
          string(error["nodeid"])
          check(!seen.include?(error["nodeid"]), "duplicate collection error")
          seen << error["nodeid"]
          exception = error["exception"]
          keys(exception, %w[type module message frames])
          string(exception["type"])
          check(exception["message"].is_a?(String), "invalid exception message")
          if exception["type"] == "ModuleNotFoundError"
            string(exception["module"])
          else
            check(exception["module"].nil?, "unexpected exception module")
          end
          check(exception["frames"].is_a?(Array) && !exception["frames"].empty?, "missing traceback frames")
          exception["frames"].each do |frame|
            keys(frame, %w[path lineno name])
            string(frame["path"])
            string(frame["name"])
            check(frame["lineno"].is_a?(Integer) && frame["lineno"] > 0, "invalid traceback line")
          end
        end
      end

      def plain(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
