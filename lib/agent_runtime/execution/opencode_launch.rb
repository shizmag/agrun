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

      def initialize(executable:, executable_sha256:, credential:)
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
        @argv = [@executable, "--standalone", "run", "--format", "json", "--model", MODEL,
          "--title", "AGRU isolated pilot"].map(&:freeze).freeze
        verify_executable!
        freeze
      end

      def inspect = "#<#{self.class} model_profile=#{MODEL.inspect} credential=[REDACTED]>"

      def to_h
        {"executable" => @executable, "executable_sha256" => @executable_sha256,
         "model_profile" => MODEL, "scope" => @scope, "transport" => "http",
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

      def verify_executable!
        raise ArgumentError, "opencode_executable_digest_mismatch" unless File.file?(@executable) && Digest::SHA256.file(@executable).hexdigest == @executable_sha256
      end

      def configuration(workspace)
        {"model" => MODEL, "smallModel" => MODEL, "plugins" => [], "mcp" => {},
         "policies" => [{"action" => "skill.use", "resource" => "*", "effect" => "deny"},
           {"action" => "tool.use", "resource" => "edit:/*", "effect" => "deny"},
           {"action" => "plugin.use", "resource" => "*", "effect" => "deny"},
           {"action" => "mcp.use", "resource" => "*", "effect" => "deny"},
           {"action" => "provider.use", "resource" => "*", "effect" => "deny"},
           {"action" => "provider.use", "resource" => "omniroute", "effect" => "allow"}],
         "providers" => {"omniroute" => {"package" => "@opencode/ai/providers/openai-compatible",
                                         "settings" => {"baseURL" => ENDPOINT, "apiKey" => "{env:OMNIROUTE_API_KEY}", "transport" => "http"},
                                         "models" => {"cx/gpt-6-luna-low" => {}}}},
         "permissions" => [{"action" => "*", "resource" => "*", "effect" => "deny"},
           {"action" => "read", "resource" => "*", "effect" => "allow"},
           {"action" => "edit", "resource" => "*", "effect" => "allow"}]}
      end
    end
  end
end
