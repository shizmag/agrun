require "json"
require "openssl"
require "securerandom"
require "tmpdir"
require_relative "../adapters/process_runner"

module AgentRuntime
  module Execution
    # Explicit offline provider: real HTTPS and relay, synthetic answers only.
    class SimulatedProvider
      IMAGE = "node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20".freeze
      attr_reader :relay_volume, :image

      def initialize
        @image = IMAGE
        @prefix = "agru-simulated-#{SecureRandom.hex(8)}"
        @relay_volume = "#{@prefix}-relay"
        @containers = []
        @volumes = []
      end

      def start(attempt_id:, cell_id:, model_profile:)
        raise "simulated provider already started" if @root || @closed
        profile = model_profile.is_a?(Hash) ? model_profile : {"model" => model_profile}
        model = profile["model"] || profile[:model] || profile["route"] || profile[:route]
        unless model == "cx/gpt-6-luna-low" && [attempt_id, cell_id].all? { |id| id.is_a?(String) && !id.empty? && id.bytesize <= 1024 }
          raise ArgumentError, "simulated provider identity/model invalid"
        end
        @root = Dir.mktmpdir("agru-simulated-provider-")
        File.chmod(0o755, @root)
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        factory = OpenSSL::X509::ExtensionFactory.new
        factory.subject_certificate = factory.issuer_certificate = cert
        cert.add_extension(factory.create_extension("subjectAltName", "DNS:localhost"))
        cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        identity = {run_id: attempt_id, architecture: cell_id, step_id: cell_id, attempt: attempt_id,
                    attempt_id: attempt_id, cell_id: cell_id}
        config = {origin: "https://localhost:9443", approvedOrigins: ["https://localhost:9443"],
                  model: model, route: "simulated-offline", timeoutMs: 10000, identity: identity,
                  inference: {max_completion_tokens: 32000, stream: true, stream_options: {include_usage: true}},
                  allowTools: true, credentialFile: "/secret/credential", caFile: "/secret/cert.pem"}
        {"credential" => "simulated-only-#{SecureRandom.hex(16)}", "key.pem" => key.to_pem,
         "cert.pem" => cert.to_pem, "config.json" => JSON.generate(config)}.each do |name, value|
          File.write(File.join(@root, name), value, perm: 0o444)
        end
        command("volume", "create", @relay_volume)
        @volumes << @relay_volume
        command(*(base + ["--rm", "--cap-add=CHOWN", "-v", "#{@relay_volume}:/relay", @image,
          "node", "-e", "require('fs').chmodSync('/relay',0o700);require('fs').chownSync('/relay',65534,65534)"]))
        name = "#{@prefix}-relay"
        @containers << name
        command(*(base + ["-d", "--name", name, "--user", "65534:65534", "-v", "#{@relay_volume}:/relay",
          "--mount", "type=bind,src=#{@root},dst=/secret,readonly",
          "--mount", "type=bind,src=#{File.join(__dir__, "provider_relay.cjs")},dst=/provider_relay.cjs,readonly",
          "--mount", "type=bind,src=#{File.join(__dir__, "simulated_provider.cjs")},dst=/simulator.cjs,readonly",
          @image, "node", "/simulator.cjs"]))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
        until logs.include?("RELAY_READY")
          raise "simulated relay startup timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.1
        end
        self
      rescue
        close
        raise
      end

      def logs(role = "relay")
        raise ArgumentError, "unknown simulator role" unless role == "relay"
        command("logs", "#{@prefix}-relay")
      end

      def close
        return if @closed
        errors = []
        @containers.reverse_each do |name|
          command("rm", "-f", name)
          @containers.delete(name)
        rescue => e
          errors << e.message
        end
        @volumes.reverse_each do |name|
          command("volume", "rm", name)
          @volumes.delete(name)
        rescue => e
          errors << e.message
        end
        if @root && File.directory?(@root)
          %w[credential key.pem cert.pem config.json].each do |name|
            path = File.join(@root, name)
            File.unlink(path) if File.file?(path)
          end
          Dir.rmdir(@root)
        end
        raise "simulated cleanup incomplete: #{errors.join("; ")}" unless errors.empty?
        @closed = true
      end

      private

      def command(*args)
        result = Adapters::ProcessRunner.new.call(argv: ["docker", *args], cwd: Dir.pwd, timeout: 15)
        raise "simulated docker failed (#{result["status"]}): #{result["stderr"]}" unless result["status"] == "success"
        result.fetch("stdout")
      end

      def base
        ["run", "--pull=never", "--network=none", "--read-only", "--cap-drop=ALL",
          "--security-opt=no-new-privileges", "--pids-limit=64", "--memory=128m", "--cpus=1"]
      end
    end
  end
end
