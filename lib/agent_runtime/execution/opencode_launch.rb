require "digest"
require "json"
require "tmpdir"
require "fileutils"

module AgentRuntime
  module Execution
    # Configuration isolation for a trusted local, explicitly authorized pilot.
    # Not an egress sandbox, tool sandbox, or request/spending enforcement layer.
    class OpenCodeLaunch
      MODEL = "omniroute/cx/gpt-6-luna-low".freeze
      ENDPOINT = "http://localhost:20128/v1".freeze
      attr_reader :executable, :executable_sha256, :model_profile, :scope, :argv

      def initialize(executable:, executable_sha256:, credential:, model_profile: nil, model_resolution: nil)
        unless executable.is_a?(String) && executable.start_with?("/") &&
            executable_sha256.is_a?(String) && executable_sha256.match?(/\A[0-9a-f]{64}\z/) &&
            credential.is_a?(String) && !credential.empty? && !credential.include?("\0")
          raise ArgumentError, "opencode_launch_invalid"
        end
        @executable = executable.dup.freeze
        @executable_sha256 = executable_sha256.dup.freeze
        @credential = credential.dup.freeze
        @model_profile = MODEL
        @scope = {"provider" => "omniroute".freeze, "endpoint" => ENDPOINT,
                  "route" => "cx/gpt-6-luna-low".freeze, "model" => "cx/gpt-6-luna-low".freeze}.freeze
        resolve_scope!(model_profile, model_resolution) if model_profile || model_resolution
        @argv = [@executable, "--standalone", "run", "--format", "json", "--model", @model_profile,
          "--title", "AGRU isolated pilot"].map(&:freeze).freeze
        verify_executable!
        freeze
      end

      def inspect = "#<#{self.class} model_profile=#{@model_profile.inspect} credential=[REDACTED]>"

      def to_h
        {"executable" => @executable, "executable_sha256" => @executable_sha256,
         "model_profile" => @model_profile, "scope" => @scope, "transport" => "http",
         "financial_exposure" => "not_hard_bounded"}
      end

      # Caller must launch with unsetenv_others: true. Returning this small hash
      # without clearing inherited environment is not credential isolation.
      def with_environment(workspace:)
        verify_executable!
        workspace = File.realpath(workspace)
        Dir.mktmpdir("agru-opencode-launch-") do |root|
          raise ArgumentError, "opencode_isolation_inside_workspace" if root.start_with?(workspace + File::SEPARATOR)
          config_path = File.join(root, "opencode.json")
          File.write(config_path, JSON.generate(configuration(workspace)), perm: 0o600)
          env = {"HOME" => root, "PATH" => "/usr/bin:/bin", "TMPDIR" => root,
                 "OPENCODE_TEST_HOME" => root, "OPENCODE_CONFIG_DIR" => File.join(root, "config"),
                 "OPENCODE_CONFIG" => config_path, "OMNIROUTE_API_KEY" => @credential,
                 "OPENCODE_DISABLE_PROJECT_CONFIG" => "1",
                 "OPENCODE_DISABLE_AUTOUPDATE" => "1", "OPENCODE_DISABLE_MODELS_FETCH" => "1",
                 "OPENCODE_DISABLE_CLAUDE_CODE" => "1", "OPENCODE_DISABLE_FREE_MODELS" => "1"}
          %w[CONFIG DATA CACHE STATE].each { |kind| env["XDG_#{kind}_HOME"] = File.join(root, kind.downcase) }
          yield env.freeze
        end
      end

      private

      def resolve_scope!(profile, resolution)
        route = resolution.fetch("route")
        parameters = resolution.fetch("variant").fetch("parameters")
        policy = profile.fetch("tool_policy")
        valid = %w[provider endpoint wire_id].all? { |key| route[key].is_a?(String) && !route[key].empty? && !route[key].include?("\0") } &&
          profile["execution_kind"] == "real_provider" && profile["provider"] == route["provider"] &&
          profile["model"] == route["wire_id"] && policy["endpoint"] == route["endpoint"] &&
          policy["route"] == route["wire_id"] && policy["model_fallback"] == false &&
          parameters.is_a?(Hash) && profile.fetch("inference_parameters", {}) == parameters &&
          (parameters.empty? || route["parameter_delivery"] == "wire_id")
        raise ArgumentError, "opencode_launch_catalog_mismatch" unless valid
        @model_profile = "#{route.fetch("provider")}/#{route.fetch("wire_id")}".freeze
        @scope = {"provider" => route.fetch("provider"), "endpoint" => route.fetch("endpoint"),
                  "route" => route.fetch("wire_id"), "model" => route.fetch("wire_id")}.transform_values { |value| value.dup.freeze }.freeze
      rescue KeyError, NoMethodError, TypeError
        raise ArgumentError, "opencode_launch_catalog_mismatch"
      end

      def verify_executable!
        raise ArgumentError, "opencode_executable_digest_mismatch" unless File.file?(@executable) && Digest::SHA256.file(@executable).hexdigest == @executable_sha256
      end

      def configuration(workspace)
        {"model" => @model_profile, "smallModel" => @model_profile, "plugins" => [], "mcp" => {},
         "policies" => [{"action" => "skill.use", "resource" => "*", "effect" => "deny"},
           {"action" => "tool.use", "resource" => "edit:/*", "effect" => "deny"},
           {"action" => "plugin.use", "resource" => "*", "effect" => "deny"},
           {"action" => "mcp.use", "resource" => "*", "effect" => "deny"},
           {"action" => "provider.use", "resource" => "*", "effect" => "deny"},
           {"action" => "provider.use", "resource" => @scope.fetch("provider"), "effect" => "allow"}],
         "providers" => {@scope.fetch("provider") => {"package" => "@opencode/ai/providers/openai-compatible",
                                                      "settings" => {"baseURL" => @scope.fetch("endpoint"), "apiKey" => "{env:OMNIROUTE_API_KEY}", "transport" => "http"},
                                                      "models" => {@scope.fetch("model") => {}}}},
         "permissions" => [{"action" => "*", "resource" => "*", "effect" => "deny"},
           {"action" => "read", "resource" => "*", "effect" => "allow"},
           {"action" => "edit", "resource" => "*", "effect" => "allow"}]}
      end
    end
  end
end
