require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "digest"
require "rubygems/package"
require "stringio"
begin
  require "fiddle/import"
rescue LoadError
  # Ruby 4 makes Fiddle optional. Never fall back to pathname traversal.
end
require_relative "../adapters/process_runner"

module AgentRuntime
  module Execution
    # Docker is the execution boundary; staging and export are consistency checks.
    # Returned export directories belong to the caller and must be captured/removed.
    class SandboxRunner
      class BoundaryError < StandardError; end

      module DescriptorFS
        if defined?(Fiddle::Importer)
          extend Fiddle::Importer

          dlload Fiddle.dlopen(nil)
          extern "int openat(int, const char*, int, int)"
        end
      end

      # Mock-only transport: never enables a Docker network or upstream mount.
      class MockRelayPolicy
        attr_reader :volume, :helper, :helper_sha256

        def initialize(volume:, helper:, helper_sha256:)
          unless volume.is_a?(String) && volume.match?(/\Aagru-mock-[a-f0-9]{16}-relay\z/) &&
              helper.is_a?(String) && helper.start_with?("/") && File.file?(helper) && !File.symlink?(helper) &&
              helper_sha256.is_a?(String) && helper_sha256.match?(/\A[a-f0-9]{64}\z/) && Digest::SHA256.file(helper).hexdigest == helper_sha256
            raise ArgumentError, "invalid reviewed mock relay policy"
          end
          @volume = volume.dup.freeze
          @helper = File.realpath(helper).freeze
          @helper_sha256 = helper_sha256.dup.freeze
          freeze
        end
      end

      def initialize(image:, limits:, process_runner: Adapters::ProcessRunner.new, network_policy: nil)
        unless image.is_a?(String) && image.match?(/\A(?:sha256:[a-f0-9]{64}|[a-z0-9][a-z0-9._\/-]*(?::[0-9]+)?(?:\/[a-z0-9._-]+)*@sha256:[a-f0-9]{64})\z/)
          raise ArgumentError, "sandbox image must be pinned by digest"
        end
        raise ArgumentError, "unreviewed sandbox network policy" unless network_policy.nil? || network_policy.instance_of?(MockRelayPolicy)
        @network_policy = network_policy
        @image = image.freeze
        @limits = limits.dup.freeze
        %w[memory_bytes pids tmpfs_bytes].each do |key|
          raise ArgumentError, "invalid sandbox #{key}" unless @limits[key].is_a?(Integer) && @limits[key].positive?
        end
        cpus = Float(@limits.fetch("cpus"))
        raise ArgumentError, "invalid sandbox cpus" unless cpus.finite? && cpus.positive?
        @runner = process_runner
      end

      def call(argv:, workspace:, timeout:, cancellation: nil, env: {})
        validate_call!(argv, timeout, env)
        result = {"status" => "failure", "stdout" => "", "stderr" => "", "exit_code" => nil,
                  "image_digest" => @image, "resource_policy" => @limits.dup,
                  "cleanup" => {"attempted" => false, "confirmed" => false}}
        name = "agru-sandbox-#{SecureRandom.hex(16)}"
        result["container_name"] = name
        attempted = false
        export = nil
        Dir.mktmpdir("agru-sandbox-") do |root|
          staging = File.join(root, "workspace")
          begin
            raise BoundaryError, "symlink workspace root" if File.symlink?(workspace)
            copy_tree!(File.realpath(workspace), staging, timeout: timeout, cancellation: cancellation)
            File.chmod(0o777, staging)
            if @network_policy
              raise BoundaryError, "mock relay helper changed" unless Digest::SHA256.file(@network_policy.helper).hexdigest == @network_policy.helper_sha256
              helper = File.join(root, "helper.cjs")
              FileUtils.copy_file(@network_policy.helper, helper)
              File.chmod(0o444, helper)
              raise BoundaryError, "mock relay helper copy mismatch" unless Digest::SHA256.file(helper).hexdigest == @network_policy.helper_sha256
            end
            attempted = true
            created = docker(create_argv(name, staging, argv, env, helper), root, 30)
            require_success!(created, "container create")
            inspected = docker(["docker", "inspect", name], root, 10)
            require_success!(inspected, "container inspect")
            policy = JSON.parse(inspected.fetch("stdout")).fetch(0)
            verify_policy!(policy, staging, argv, env, helper)
            result["container_inspect"] = evidence(policy)
            require_success!(docker(["docker", "start", name], root, 10), "container start")
            provision = docker(["docker", "exec", name, "/bin/sh", "-c", "cp -Rp /input/. /workspace/"], root, timeout, cancellation)
            result["status"] = provision["status"]
            require_success!(provision, "workspace provision")
            raw = docker(["docker", "exec", name, *argv], root, timeout, cancellation)
            %w[status stdout stderr exit_code duration stdout_truncated stderr_truncated].each { |key| result[key] = raw[key] }
            # docker start --attach's client status is insufficient container evidence.
            if raw["status"] == "success"
              finished = docker(["docker", "inspect", name], root, 10)
              require_success!(finished, "container final inspect")
              state = JSON.parse(finished.fetch("stdout")).fetch(0).fetch("State")
              raise BoundaryError, "container state invalid" unless state["Running"] == true && state["OOMKilled"] == false && state["Error"] == ""
              archive = docker(["docker", "exec", name, "/bin/tar", "-cf", "-", "-C", "/workspace", "."], root, timeout, cancellation)
              require_success!(archive, "workspace archive")
              require_success!(docker(["docker", "pause", name], root, 10), "stop export writers")
              captured = File.join(root, "captured")
              Dir.mkdir(captured)
              extract_archive!(archive.fetch("stdout"), captured)
            end
          rescue => error
            result["status"] = "failure" unless %w[timeout cancelled].include?(result["status"])
            result["error"] = "#{error.class}: #{error.message}"
          ensure
            if attempted
              result["cleanup"]["attempted"] = true
              begin
                removed = docker(["docker", "rm", "--force", name], root, 10)
                require_success!(removed, "container cleanup")
                result["cleanup"]["confirmed"] = true
              rescue => error
                result["status"] = "failure"
                result["cleanup"]["error"] = "#{error.class}: #{error.message}"
              end
            end
          end
          if result["status"] == "success" && result["cleanup"]["confirmed"]
            begin
              raise BoundaryError, "truncated sandbox execution evidence" if result["stdout_truncated"] || result["stderr_truncated"]
              # Validate diagnostics, but never promote a pre-pause archive to a
              # submission. Docker's archive endpoint did not expose tmpfs data.
              export = Dir.mktmpdir("agru-sandbox-diagnostic-")
              destination = File.join(export, "repository")
              copy_tree!(captured, destination, timeout: timeout, cancellation: cancellation)
              FileUtils.remove_entry(export)
              export = nil
              result["status"] = "blocked"
              result["error"] = "writer_quiescence_unsupported: tmpfs archive collected before container pause; no accepted export"
            rescue => error
              FileUtils.remove_entry(export) if export
              result["status"] = "failure"
              result["error"] = "#{error.class}: #{error.message}"
            end
          end
        end
        result
      end

      private

      def extract_archive!(bytes, destination)
        Gem::Package::TarReader.new(StringIO.new(bytes.b)) do |tar|
          tar.each do |entry|
            path = entry.full_name.delete_prefix("./").delete_suffix("/")
            next if path.empty? && entry.directory?
            raise BoundaryError, "unsafe workspace/export entry: #{path}" if path.start_with?("/") || path.split("/").any? { |part| part == ".." || part.empty? }
            target = File.join(destination, path)
            if entry.directory?
              FileUtils.mkdir_p(target)
            elsif entry.file? && entry.header.typeflag == "0"
              FileUtils.mkdir_p(File.dirname(target))
              File.open(target, File::WRONLY | File::CREAT | File::EXCL, entry.header.mode & 0o777) { |file| file.write(entry.read) }
            else
              raise BoundaryError, "unsafe workspace/export entry: #{path}"
            end
          end
        end
      end

      def validate_call!(argv, timeout, env)
        unless argv.is_a?(Array) && !argv.empty? && argv.all? { |value| value.is_a?(String) && !value.include?("\0") } && argv.first.start_with?("/")
          raise ArgumentError, "sandbox argv requires an absolute container executable"
        end
        seconds = Float(timeout)
        raise ArgumentError, "invalid sandbox timeout" unless seconds.finite? && seconds.positive?
        unless env.is_a?(Hash) && env.all? { |key, value| key.is_a?(String) && key.match?(/\A[A-Z_][A-Z0-9_]*\z/) && value.is_a?(String) && !value.include?("\0") }
          raise ArgumentError, "invalid sandbox environment"
        end
      end

      def docker(argv, cwd, timeout, cancellation = nil)
        # Docker itself needs a local endpoint, but not ambient credentials/config.
        clean = ENV.keys.to_h { |key| [key, nil] }
        clean["PATH"] = ENV.fetch("PATH", "/usr/bin:/bin")
        @runner.call(argv: argv, cwd: cwd, timeout: timeout, cancellation: cancellation, env: clean)
      end

      def require_success!(raw, operation)
        unless raw["status"] == "success" && raw["exit_code"] == 0 && !raw["stdout_truncated"] && !raw["stderr_truncated"]
          raise BoundaryError, "#{operation} failed"
        end
      end

      def create_argv(name, staging, argv, env, helper)
        ["docker", "create", "--name", name, "--pull=never", "--read-only", "--network=none", "--user=65534:65534",
          "--cap-drop=ALL", "--security-opt=no-new-privileges", "--cpus=#{@limits.fetch("cpus")}",
          "--memory=#{@limits.fetch("memory_bytes")}", "--memory-swap=#{@limits.fetch("memory_bytes")}", "--pids-limit=#{@limits.fetch("pids")}",
          "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=#{@limits.fetch("tmpfs_bytes")},mode=1777",
          "--tmpfs", workspace_tmpfs,
          "--mount", "type=bind,src=#{staging},dst=/input,readonly,bind-propagation=rprivate", "--workdir=/workspace",
          *relay_mounts(helper),
          *env.sort.flat_map { |key, value| ["--env", "#{key}=#{value}"] }, "--entrypoint", "/bin/sh", @image, "-c", "while :; do sleep 3600; done"]
      end

      def workspace_tmpfs
        "/workspace:rw,exec,nosuid,nodev,size=#{@limits.fetch("workspace_bytes", 67_108_864)},uid=65534,gid=65534,mode=0700"
      end

      def relay_mounts(helper)
        return [] unless @network_policy
        ["--mount", "type=volume,src=#{@network_policy.volume},dst=/relay,readonly,volume-nocopy",
          "--mount", "type=bind,src=#{helper},dst=/helper.cjs,readonly,bind-propagation=rprivate"]
      end

      def verify_policy!(data, staging, argv, env, helper)
        host = data.fetch("HostConfig")
        config = data.fetch("Config")
        raise BoundaryError, "local image identity mismatch" if @image.start_with?("sha256:") && data["Image"] != @image
        mounts = data.fetch("Mounts")
        workspace_mount = mounts.find { |mount| mount["Destination"] == "/input" }
        expected_mount = workspace_mount && same_mount_source?(workspace_mount["Source"], staging) && workspace_mount.values_at("Type", "Destination", "RW", "Propagation") == ["bind", "/input", false, "rprivate"]
        if @network_policy
          relay = mounts.find { |mount| mount["Destination"] == "/relay" }
          asset = mounts.find { |mount| mount["Destination"] == "/helper.cjs" }
          expected_mount &&= mounts.length == 3 && relay && relay.values_at("Type", "Name", "RW") == ["volume", @network_policy.volume, false] &&
            asset && same_mount_source?(asset["Source"], helper) && asset.values_at("Type", "RW", "Propagation") == ["bind", false, "rprivate"]
        else
          expected_mount &&= mounts.length == 1
        end
        valid = expected_mount && host["NetworkMode"] == "none" && host["ReadonlyRootfs"] == true && host["Privileged"] == false &&
          host["CapDrop"] == ["ALL"] && (host["CapAdd"] || []).empty? && host["SecurityOpt"] == ["no-new-privileges"] &&
          host["Memory"] == @limits["memory_bytes"] && host["MemorySwap"] == @limits["memory_bytes"] && host["PidsLimit"] == @limits["pids"] &&
          host["NanoCpus"] == (Float(@limits["cpus"]) * 1_000_000_000).to_i &&
          host["Tmpfs"] == {"/tmp" => "rw,noexec,nosuid,nodev,size=#{@limits["tmpfs_bytes"]},mode=1777", "/workspace" => workspace_tmpfs.split(":", 2).last} &&
          (host["Devices"] || []).empty? && (host["Binds"] || []).empty? &&
          config["User"] == "65534:65534" && config["WorkingDir"] == "/workspace" && config["Image"] == @image &&
          config["Entrypoint"] == ["/bin/sh"] && config["Cmd"] == ["-c", "while :; do sleep 3600; done"] &&
          env.all? { |key, value| config.fetch("Env").include?("#{key}=#{value}") } &&
          config.fetch("Env").all? { |entry| allowed_image_env?(entry, env) }
        raise BoundaryError, "effective sandbox policy mismatch" unless valid
      end

      def allowed_image_env?(entry, env)
        key, value = entry.split("=", 2)
        return value == env[key] if env.key?(key)
        # Ordinary clean base-image declarations only. Credentials/config must be explicit.
        case key
        when "PATH"
          ["/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"].include?(value)
        when "NODE_VERSION", "YARN_VERSION", "PYTHON_VERSION"
          value.match?(/\A[0-9]+(?:\.[0-9]+){1,3}\z/)
        when "LANG"
          ["C.UTF-8", "C.utf8"].include?(value)
        when "GPG_KEY", "PYTHON_SHA256"
          value.match?(/\A[A-Fa-f0-9]{40,64}\z/)
        else
          false
        end
      end

      def same_mount_source?(actual, expected)
        return false unless actual.is_a?(String)
        candidate = actual
        candidate = candidate.delete_prefix("/host_mnt") if RUBY_PLATFORM.include?("darwin") && candidate.start_with?("/host_mnt/")
        File.identical?(candidate, expected) && File.realpath(candidate) == File.realpath(expected)
      rescue SystemCallError
        false
      end

      def evidence(data)
        {"Id" => data.fetch("Id"), "Image" => data.fetch("Image"),
         "HostConfig" => data.fetch("HostConfig").slice("NetworkMode", "ReadonlyRootfs", "Privileged", "CapDrop", "CapAdd", "SecurityOpt", "Memory", "MemorySwap", "PidsLimit", "NanoCpus", "Tmpfs"),
         "Mounts" => data.fetch("Mounts"), "User" => data.fetch("Config").fetch("User")}
      end

      def copy_tree!(source, destination, timeout:, cancellation:)
        raise BoundaryError, "descriptor-relative copying unavailable: Fiddle dependency required" unless DescriptorFS.respond_to?(:openat)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(timeout)
        bytes = 0
        entries = 0
        check = lambda do
          raise BoundaryError, "workspace copy cancelled" if cancellation&.cancelled?
          raise BoundaryError, "workspace copy deadline exceeded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise BoundaryError, "workspace byte limit exceeded" if bytes > @limits.fetch("workspace_bytes", 67_108_864)
          raise BoundaryError, "workspace entry limit exceeded" if entries > @limits.fetch("workspace_entries", 10_000)
        end
        Dir.mkdir(destination, 0o777)
        File.chmod(0o777, destination)
        manifest = []
        walk = lambda do |directory, relative|
          check.call
          raise BoundaryError, "workspace must be a directory" unless directory.stat.directory?
          names = descriptor_children(directory)
          names.each do |name|
            entries += 1
            check.call
            raise BoundaryError, "invalid export path" if [".", ".."].include?(name) || name.include?("/")
            path = File.join(relative, name)
            raise BoundaryError, "workspace depth limit exceeded" if path.count("/") >= @limits.fetch("workspace_depth", 64)
            output = File.join(destination, path)
            fd = DescriptorFS.openat(directory.fileno, name, File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
            raise BoundaryError, "unsafe workspace/export entry: #{path}" if fd < 0
            file = IO.for_fd(fd)
            begin
              stat = file.stat
              if stat.directory?
                Dir.mkdir(output, 0o777)
                File.chmod(0o777, output)
                manifest << [path, "directory"]
                walk.call(file, path)
              elsif stat.file? && stat.nlink == 1
                File.open(output, File::WRONLY | File::CREAT | File::EXCL, (stat.mode & 0o111 == 0) ? 0o666 : 0o777) do |target|
                  while (chunk = file.read(65_536))
                    bytes += chunk.bytesize
                    check.call
                    target.write(chunk)
                  end
                end
                File.chmod((stat.mode & 0o111).zero? ? 0o666 : 0o777, output)
                manifest << [path, "file", Digest::SHA256.file(output).hexdigest, (stat.mode & 0o111) != 0]
              else
                raise BoundaryError, "unsafe workspace/export entry: #{path}"
              end
            ensure
              file.close
            end
          end
        end
        File.open(source, File::RDONLY | File::NOFOLLOW) { |directory| walk.call(directory, "") }
        manifest
      end

      def descriptor_children(directory)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          begin
            names = Dir.fchdir(directory.fileno) { Dir.children(".").take(@limits.fetch("workspace_entries", 10_000) + 1).sort }
            Marshal.dump(names, writer)
            writer.close
            exit! 0
          rescue
            exit! 1
          end
        end
        writer.close
        names = Marshal.load(reader)
        Process.wait(pid)
        raise BoundaryError, "descriptor directory enumeration failed" unless $?.success?
        names
      ensure
        reader&.close
        writer&.close unless writer&.closed?
        if pid
          begin
            Process.wait(pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end
    end
  end
end
