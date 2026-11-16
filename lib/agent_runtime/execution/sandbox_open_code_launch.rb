require "json"

module AgentRuntime
  module Execution
    # Mock-only transport plan. SandboxRunner, not application policy, owns confinement.
    class SandboxOpenCodeLaunch
      attr_reader :executable, :executable_sha256, :model

      def initialize(executable:, executable_sha256:, endpoint:, model:, mock_only:, provider:, wire_model:, transport_mode: nil)
        transport_valid = (mock_only == true && transport_mode.nil?) ||
          (mock_only == false && transport_mode == "provider_relay" && wire_model == "cx/gpt-6-luna-low")
        unless transport_valid && executable == "/usr/local/bin/opencode" &&
            executable_sha256.match?(/\A[0-9a-f]{64}\z/) &&
            endpoint == "http://127.0.0.1:18080/v1" && provider.match?(/\A[a-zA-Z0-9_-]+\z/) &&
            wire_model.is_a?(String) && !wire_model.empty? && model == "#{provider}/#{wire_model}"
          raise ArgumentError, "sandbox_mock_launch_invalid"
        end
        @executable, @executable_sha256, @endpoint, @model = [executable, executable_sha256, endpoint, model].map { |value| value.dup.freeze }
        @provider, @wire_model = provider.dup.freeze, wire_model.dup.freeze
        freeze
      end

      def with_extensions(**)
        raise ArgumentError, "sandbox_extensions_unsupported"
      end

      def argv(prompt)
        raise ArgumentError, "prompt required" unless prompt.is_a?(String) && !prompt.empty? && !prompt.include?("\0")
        script = <<~SH
          printf '%s  %s\\n' "$1" "$2" | sha256sum -c - >/tmp/identity.log 2>&1 || exit 72
          shift
          node /helper.cjs bridge >/tmp/bridge.log 2>&1 & bridge=$!
          trap 'kill $bridge 2>/dev/null || true' EXIT
          for i in $(seq 1 100); do
            grep -q '"ready":"bridge"' /tmp/bridge.log && break
            kill -0 "$bridge" || exit 70
            sleep 0.1
          done
          grep -q '"ready":"bridge"' /tmp/bridge.log || exit 71
          exec "$@"
        SH
        ["/bin/sh", "-c", script, "agru-mock", executable_sha256, executable, "--standalone", "run", "--format", "json", "--model", model, "--", prompt]
      end

      def environment
        {"HOME" => "/tmp/agru-home", "PATH" => "/usr/local/bin:/usr/bin:/bin", "TMPDIR" => "/tmp",
         "XDG_CONFIG_HOME" => "/tmp/agru-home/config", "XDG_DATA_HOME" => "/tmp/agru-home/data",
         "XDG_CACHE_HOME" => "/tmp/agru-home/cache", "XDG_STATE_HOME" => "/tmp/agru-home/state",
         "OPENCODE_CONFIG_CONTENT" => JSON.generate(configuration),
         "OPENCODE_DISABLE_PROJECT_CONFIG" => "1", "OPENCODE_DISABLE_AUTOUPDATE" => "1",
         "OPENCODE_DISABLE_MODELS_FETCH" => "1", "OPENCODE_DISABLE_FREE_MODELS" => "1",
         "OPENCODE_DISABLE_CLAUDE_CODE" => "1"}
      end

      def to_h
        {"mode" => "mock-only", "executable" => executable, "executable_sha256" => executable_sha256, "model" => model}
      end

      private

      def configuration
        {"model" => model, "smallModel" => model, "plugins" => [], "mcp" => {}, "lsp" => false,
         "agents" => {"title" => {"disabled" => true}},
         "providers" => {@provider => {"package" => "@opencode/ai/providers/openai-compatible", "settings" => {"transport" => "http", "baseURL" => @endpoint, "apiKey" => "mock-only"},
                                       "models" => {@wire_model => {"name" => "Mock only"}}}},
         "policies" => [
           {"action" => "provider.use", "resource" => "*", "effect" => "deny"},
           {"action" => "provider.use", "resource" => @provider, "effect" => "allow"},
           *%w[plugin.use mcp.use skill.use].map { |action| {"action" => action, "resource" => "*", "effect" => "deny"} },
            {"action" => "tool.use", "resource" => "bash", "effect" => "allow"},
           {"action" => "tool.use", "resource" => "shell", "effect" => "allow"}
         ]}
      end
    end
  end
end
