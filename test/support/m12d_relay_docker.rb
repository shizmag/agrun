require_relative "m12c_relay_docker"
require "openssl"

# Controlled offline upstream only; shares S3 lifecycle and private volume layout.
class M12dRelayDocker < M12cRelayDocker
  def close
    ["key.pem", "cert.pem"].each do |name|
      path = File.join(@root, name) if @root
      File.unlink(path) if path && File.file?(path)
    end
    super
  end

  def start
    raise "already started" if @root
    @root = Dir.mktmpdir("agru-transport-")
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
    {"credential" => "simulated-only-#{SecureRandom.hex(16)}", "key.pem" => key.to_pem, "cert.pem" => cert.to_pem}.each do |name, value|
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
      "--mount", "type=bind,src=#{File.expand_path("../../lib/agent_runtime/execution/provider_relay.cjs", __dir__)},dst=/provider_relay.cjs,readonly",
      "--mount", "type=bind,src=#{File.expand_path("m12d_simulated_upstream.cjs", __dir__)},dst=/simulator.cjs,readonly",
      @image, "node", "/simulator.cjs"]))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until logs("relay").include?("RELAY_READY")
      raise "relay startup failed: #{logs("relay")}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    self
  rescue
    close
    raise
  end
end
