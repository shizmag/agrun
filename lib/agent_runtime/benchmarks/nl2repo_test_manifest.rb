require "digest"
require "json"
require_relative "adapter"

module AgentRuntime
  module Benchmarks
    # Trusted preparation artifact, never inferred from a candidate collection.
    # Pin the complete reviewed bytes: changing even a valid-looking identity or
    # selection setting requires explicit review and a new manifest digest.
    class NL2RepoTestManifest
      DEFAULT_PATH = File.expand_path("../../../benchmarks/nl2repo/retrying-test-manifest.json", __dir__)
      APPROVED_SHA256 = "3861f33b79c0b6d8f1c4a81ab382b7fe6f4ddbb9d865e3d96e5fdf0f0bb9bcc8"

      attr_reader :digest, :identity, :expected_nodeids
      alias_method :nodeids, :expected_nodeids

      def initialize(path: DEFAULT_PATH)
        bytes = File.binread(path)
        @digest = Digest::SHA256.hexdigest(bytes).freeze
        raise ArgumentError, "unapproved retrying test manifest digest" unless @digest == APPROVED_SHA256
        data = JSON.parse(bytes)
        @expected_nodeids = Adapter.freeze_json(data.fetch("tests").map { |entry| entry.fetch("nodeid") })
        @parameter_ids = Adapter.freeze_json(data.fetch("tests").to_h { |entry| [entry.fetch("nodeid"), entry.fetch("parameter_id")] })
        @identity = Adapter.freeze_json(data.except("tests").merge("manifest_sha256" => @digest))
      rescue JSON::ParserError, KeyError, TypeError, Errno::ENOENT, Errno::EACCES => error
        raise ArgumentError, "invalid retrying test manifest: #{error.message}"
      end

      # Input must already use the configured canonical test-root mapping.
      # No basename matching, path cleanup, or parameter suffix stripping here.
      def validate_collection!(nodeids:, test_source_sha256:, parameter_ids: nil)
        unless test_source_sha256 == @identity.fetch("test_source_sha256")
          raise ArgumentError, "retrying test source digest mismatch"
        end
        unless nodeids.is_a?(Array) && nodeids.all? { |nodeid| nodeid.is_a?(String) } &&
            nodeids.length == @expected_nodeids.length && nodeids.uniq.length == nodeids.length &&
            nodeids.sort == @expected_nodeids.sort
          raise ArgumentError, "retrying collection must exactly match the authoritative identities"
        end
        unless parameter_ids.nil? || parameter_ids == @parameter_ids
          raise ArgumentError, "retrying collection parameter mapping mismatch"
        end
        true
      end
    end
  end
end
