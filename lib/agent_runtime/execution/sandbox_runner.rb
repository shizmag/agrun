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
          unless volume.is_a?(String) && volume.match?(/\Aagru-(?:mock|simulated)-[a-f0-9]{16}-relay\z/) &&
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
        require_relative "sandbox_deadline"
        require_relative "sandbox_archive_transport"
        deadline = SandboxDeadline.new(timeout: timeout, cancellation: cancellation)
        validate_call!(argv, timeout, env)
        result = {"status" => "failure", "stdout" => "", "stderr" => "", "exit_code" => nil,
                  "image_digest" => @image, "resource_policy" => @limits.dup,
                  "cleanup" => {"attempted" => false, "confirmed" => false}}
        name = "agru-sandbox-#{SecureRandom.hex(16)}"
        result["container_name"] = name
        attempted = false
        export = nil
        root = Dir.mktmpdir("agru-sandbox-")
        begin
          staging = File.join(root, "workspace")
          begin
            deadline.check!(phase: "supervisor snapshot")
            supervisor_bytes = File.binread(supervisor_path)
            supervisor_digest = Digest::SHA256.hexdigest(supervisor_bytes)
            snapshot = File.join(root, "supervisor.py")
            File.open(snapshot, File::WRONLY | File::CREAT | File::EXCL, 0o444) { |io| io.write(supervisor_bytes) }
            raise BoundaryError, "supervisor snapshot mismatch" unless Digest::SHA256.file(snapshot).hexdigest == supervisor_digest && Digest::SHA256.file(supervisor_path).hexdigest == supervisor_digest
            result["supervisor_sha256"] = supervisor_digest
            deadline.check!(phase: "supervisor snapshot")
            raise BoundaryError, "symlink workspace root" if File.symlink?(workspace)
            input_manifest = copy_tree!(File.realpath(workspace), staging, timeout: timeout, cancellation: cancellation, deadline: deadline)
            raise BoundaryError, "input regular-file limit exceeded (1024)" if input_manifest.count { |entry| entry[1] == "file" } > 1024
            raise BoundaryError, "input directory limit exceeded (1024)" if input_manifest.count { |entry| entry[1] == "directory" } > 1024
            if @network_policy
              raise BoundaryError, "mock relay helper changed" unless Digest::SHA256.file(@network_policy.helper).hexdigest == @network_policy.helper_sha256
              helper = File.join(root, "helper.cjs")
              FileUtils.copy_file(@network_policy.helper, helper)
              File.chmod(0o444, helper)
              raise BoundaryError, "mock relay helper copy mismatch" unless Digest::SHA256.file(helper).hexdigest == @network_policy.helper_sha256
            end
            attempted = true
            created = docker(create_argv(name, staging, argv, env, helper, supervisor: snapshot), root, 30, cancellation, deadline: deadline)
            require_success!(created, "container create")
            inspected = docker(["docker", "inspect", name], root, 10, cancellation, deadline: deadline)
            require_success!(inspected, "container inspect")
            policy = JSON.parse(inspected.fetch("stdout")).fetch(0)
            result["container_inspect"] = evidence(policy)
            verify_policy!(policy, staging, argv, env, helper, supervisor: snapshot)
            result["container_inspect"] = evidence(policy)
            require_success!(docker(["docker", "start", name], root, 10, cancellation, deadline: deadline), "container start")
            require_success!(docker(["docker", "exec", "--user", "0:0", name, "/bin/touch", "/control/start"], root, 10, cancellation, deadline: deadline), "supervisor start")
            loop do
              logs = docker(["docker", "logs", name], root, 10, cancellation, deadline: deadline)
              require_success!(logs, "supervisor readiness")
              unless logs.fetch("stdout").empty?
                raise BoundaryError, "invalid supervisor readiness" unless JSON.parse(logs.fetch("stdout")) == {"protocol" => 1, "quiescent" => true}
                break
              end
              sleep [0.02, deadline.remaining!(phase: "quiesce")].min
            end
            trusted = docker(["docker", "exec", "--user", "0:0", name, "/bin/cat", "/control/status.json"], root, 10, cancellation, deadline: deadline)
            require_success!(trusted, "supervisor status")
            report = JSON.parse(trusted.fetch("stdout"))
            raise BoundaryError, "invalid supervisor status" unless report["protocol"] == 1 && report["quiescent"] == true && report["exit_code"].is_a?(Integer)
            result["exit_code"] = report["exit_code"]
            result["status"] = report["exit_code"].zero? ? "success" : "failure"
            %w[stdout stderr].each do |stream|
              path = File.join(root, "agent.#{stream}")
              output = SandboxArchiveTransport.new.call(argv: ["docker", "exec", "--user", "0:0", name, "/bin/cat", "/control/agent.#{stream}"], cwd: root, path: path, deadline: deadline, max_bytes: 1_048_576)
              raise SandboxDeadline::Exceeded.new(status: output["status"], phase: "export #{stream}") if %w[timeout cancelled].include?(output["status"])
              require_success!(output, "agent #{stream}")
              result[stream] = File.binread(path)
            end
            if result["status"] == "success"
              finished = docker(["docker", "inspect", name], root, 10, cancellation, deadline: deadline)
              require_success!(finished, "container final inspect")
              state = JSON.parse(finished.fetch("stdout")).fetch(0).fetch("State")
              raise BoundaryError, "container state invalid" unless state["Running"] == true && state["OOMKilled"] == false && state["Error"] == ""
              archive_path = File.join(root, "archive.tar")
              archive = SandboxArchiveTransport.new.call(argv: ["docker", "exec", "--user", "0:0", name, "/bin/cat", "/control/archive.tar"], cwd: root, path: archive_path, deadline: deadline, max_bytes: @limits.fetch("workspace_bytes", 67_108_864) + 16_777_216)
              raise SandboxDeadline::Exceeded.new(status: archive["status"], phase: "export archive") if %w[timeout cancelled].include?(archive["status"])
              require_success!(archive, "workspace archive")
              captured = File.join(root, "captured")
              Dir.mkdir(captured)
              File.open(archive_path, "rb") { |io| extract_archive!(io, captured, deadline: deadline) }
            end
          rescue SandboxDeadline::Exceeded => error
            result["status"] = error.status
            result["error"] = error.message
          rescue => error
            result["status"] = "failure" unless %w[timeout cancelled].include?(result["status"])
            result["error"] = "#{error.class}: #{error.message}"
          ensure
            if attempted
              result["cleanup"]["attempted"] = true
              begin
                cleanup_deadline = deadline.emergency_cleanup(timeout: 10)
                result["cleanup"]["timeout"] = 10
                result["cleanup"]["process_runner_allowance"] = Adapters::ProcessRunner::CLEANUP_TIMEOUT
                removed = docker(["docker", "rm", "--force", name], root, 10, nil, deadline: cleanup_deadline)
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
              export = Dir.mktmpdir("agru-sandbox-export-")
              destination = File.join(export, "repository")
              manifest = copy_tree!(captured, destination, timeout: timeout, cancellation: cancellation, deadline: deadline)
              deadline.check!(phase: "verify")
              result["export_directory"] = destination
              result["export"] = {"path" => destination, "digest" => Digest::SHA256.hexdigest(JSON.generate(manifest)), "manifest" => manifest}
            rescue => error
              result["status"] = error.is_a?(SandboxDeadline::Exceeded) ? error.status : "failure"
              result["error"] = "#{error.class}: #{error.message}"
            end
          end
        ensure
          begin
            cleanup_deadline = deadline.emergency_cleanup(timeout: 10)
            remove_private_tree!(root, deadline: cleanup_deadline)
            remove_private_tree!(export, deadline: cleanup_deadline) if export && result["status"] != "success"
            result["cleanup"]["private_confirmed"] = true
          rescue => error
            result["status"] = "failure"
            result.delete("export")
            result.delete("export_directory")
            result["cleanup"]["private_confirmed"] = false
            result["cleanup"]["private_error"] = "#{error.class}: #{error.message}"
          end
        end
        result
      end

      private

      # Only call for our private temporary roots. lstat never follows links;
      # each filesystem operation spends the same emergency cleanup budget.
      def remove_private_tree!(path, deadline:)
        deadline.check!(phase: "private cleanup")
        stat = File.lstat(path)
        if stat.directory?
          File.chmod(0o700, path)
          Dir.each_child(path) do |name|
            deadline.check!(phase: "private cleanup")
            remove_private_tree!(File.join(path, name), deadline: deadline)
          end
          deadline.check!(phase: "private cleanup")
          Dir.rmdir(path)
        else
          deadline.check!(phase: "private cleanup")
          File.unlink(path)
        end
      rescue Errno::ENOENT
        nil
      end

      def extract_archive!(bytes, destination, deadline: nil)
        io = bytes.respond_to?(:read) ? bytes : StringIO.new(bytes.b)
        total = 0
        entries = 0
        seen = {}
        directories = []
        archive_bytes = 0
        archive_limit = @limits.fetch("workspace_bytes", 67_108_864) + (@limits.fetch("workspace_entries", 10_000) + 1) * 1024 + 1024
        read_exact = lambda do |size|
          data = +"".b
          while data.bytesize < size
            deadline&.check!(phase: "archive extraction")
            chunk = io.read(size - data.bytesize)
            raise BoundaryError, "incomplete workspace archive" if chunk.nil? || chunk.empty?
            data << chunk
            archive_bytes += chunk.bytesize
            raise BoundaryError, "workspace archive byte limit exceeded" if archive_bytes > archive_limit
          end
          data
        end
        loop do
          block = read_exact.call(512)
          if block == "\0" * 512
            raise BoundaryError, "incomplete workspace archive terminator" unless read_exact.call(512) == "\0" * 512
            while (chunk = io.read(65_536)) && !chunk.empty?
              deadline&.check!(phase: "archive extraction")
              archive_bytes += chunk.bytesize
              raise BoundaryError, "workspace archive byte limit exceeded" if archive_bytes > archive_limit
              raise BoundaryError, "unexpected workspace archive trailing data" unless chunk.bytes.all?(&:zero?)
            end
            break
          end
          expected = block.byteslice(148, 8).delete("\0 ")
          raise BoundaryError, "invalid workspace archive checksum" unless expected.match?(/\A[0-7]+\z/) && expected.to_i(8) == (block.byteslice(0, 148) + " " * 8 + block.byteslice(156, 356)).bytes.sum
          header = Gem::Package::TarHeader.from(StringIO.new(block))
          path = [header.prefix, header.name].reject(&:empty?).join("/").delete_prefix("./").delete_suffix("/")
          directory = header.typeflag == "5"
          raise BoundaryError, "unsafe workspace/export entry: #{path}" unless directory || header.typeflag == "0"
          raise BoundaryError, "privileged workspace mode: #{path}" unless (header.mode & ~0o777).zero?
          if path.empty? && directory
            raise BoundaryError, "invalid archive directory size" unless header.size.zero?
            raise BoundaryError, "duplicate workspace archive root" if seen[""]
            seen[""] = true
            directories << [destination, header.mode]
            next
          end
          raise BoundaryError, "unsafe workspace/export entry: #{path}" if path.empty? || path.start_with?("/") || path.include?("\0") || path.split("/", -1).any? { |part| [".", "..", ""].include?(part) }
          raise BoundaryError, "duplicate workspace archive entry: #{path}" if seen[path]
          seen[path] = true
          entries += 1
          total += header.size
          raise BoundaryError, "workspace byte limit exceeded" if total > @limits.fetch("workspace_bytes", 67_108_864)
          raise BoundaryError, "workspace entry limit exceeded" if entries > @limits.fetch("workspace_entries", 10_000)
          raise BoundaryError, "workspace depth limit exceeded" if path.count("/") >= @limits.fetch("workspace_depth", 64)
          target = File.join(destination, path)
          if directory
            raise BoundaryError, "invalid archive directory size" unless header.size.zero?
            FileUtils.mkdir_p(target, mode: 0o700)
            directories << [target, header.mode]
          else
            FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
            File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              remaining = header.size
              while remaining.positive?
                chunk = read_exact.call([remaining, 65_536].min)
                file.write(chunk)
                remaining -= chunk.bytesize
              end
              file.chmod(header.mode)
            end
            read_exact.call((512 - header.size % 512) % 512)
          end
        end
        directories.sort_by { |path, _| -path.count("/") }.each do |path, mode|
          deadline&.check!(phase: "archive directory metadata")
          File.chmod(mode, path)
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
        allowed = %w[PATH HOME TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME OPENCODE_CONFIG_CONTENT OPENCODE_DISABLE_PROJECT_CONFIG OPENCODE_DISABLE_AUTOUPDATE OPENCODE_DISABLE_MODELS_FETCH OPENCODE_DISABLE_FREE_MODELS OPENCODE_DISABLE_CLAUDE_CODE]
        raise ArgumentError, "unsupported sandbox environment key" unless (env.keys - allowed).empty?
      end

      def docker(argv, cwd, timeout, cancellation = nil, deadline: nil)
        # Docker itself needs a local endpoint, but not ambient credentials/config.
        clean = ENV.keys.to_h { |key| [key, nil] }
        clean["PATH"] = ENV.fetch("PATH", "/usr/bin:/bin")
        limit = deadline ? deadline.remaining!(phase: argv[1], cap: timeout) : timeout
        raw = @runner.call(argv: argv, cwd: cwd, timeout: limit, cancellation: cancellation, env: clean)
        raise SandboxDeadline::Exceeded.new(status: raw["status"], phase: argv[1]) if deadline && %w[timeout cancelled].include?(raw["status"])
        deadline&.check!(phase: argv[1])
        raw
      end

      def require_success!(raw, operation)
        unless raw["status"] == "success" && raw["exit_code"] == 0 && !raw["stdout_truncated"] && !raw["stderr_truncated"]
          raise BoundaryError, "#{operation} failed"
        end
      end

      def create_argv(name, staging, argv, env, helper, supervisor: supervisor_path)
        ["docker", "create", "--name", name, "--pull=never", "--read-only", "--network=none", "--user=0:0",
          "--cap-drop=ALL", "--cap-add=SETUID", "--cap-add=SETGID", "--cap-add=KILL", "--security-opt=no-new-privileges", "--cpus=#{@limits.fetch("cpus")}",
          "--memory=#{@limits.fetch("memory_bytes")}", "--memory-swap=#{@limits.fetch("memory_bytes")}", "--pids-limit=#{@limits.fetch("pids")}",
          "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=#{@limits.fetch("tmpfs_bytes")},mode=1777",
          "--tmpfs", workspace_tmpfs,
          "--tmpfs", control_tmpfs,
          "--mount", "type=bind,src=#{supervisor},dst=/supervisor.py,readonly,bind-propagation=rprivate",
          "--mount", "type=bind,src=#{staging},dst=/input,readonly,bind-propagation=rprivate", "--workdir=/workspace",
          *relay_mounts(helper),
          *env.sort.flat_map { |key, value| ["--env", "#{key}=#{value}"] }, "--entrypoint", "/usr/bin/python3", @image, "-I", "-S", "/supervisor.py", *argv]
      end

      def supervisor_path
        File.realpath(File.join(__dir__, "sandbox_supervisor.py"))
      end

      def control_tmpfs
        "/control:rw,noexec,nosuid,nodev,size=#{@limits.fetch("workspace_bytes", 67_108_864) + 16_777_216},mode=0700"
      end

      def workspace_tmpfs
        "/workspace:rw,exec,nosuid,nodev,size=#{@limits.fetch("workspace_bytes", 67_108_864)},uid=65534,gid=65534,mode=0700"
      end

      def relay_mounts(helper)
        return [] unless @network_policy
        ["--mount", "type=volume,src=#{@network_policy.volume},dst=/relay,readonly,volume-nocopy",
          "--mount", "type=bind,src=#{helper},dst=/helper.cjs,readonly,bind-propagation=rprivate"]
      end

      def verify_policy!(data, staging, argv, env, helper, supervisor: supervisor_path)
        host = data.fetch("HostConfig")
        config = data.fetch("Config")
        raise BoundaryError, "local image identity mismatch" if @image.start_with?("sha256:") && data["Image"] != @image
        mounts = data.fetch("Mounts")
        workspace_mount = mounts.find { |mount| mount["Destination"] == "/input" }
        expected_mount = workspace_mount && same_mount_source?(workspace_mount["Source"], staging) && workspace_mount.values_at("Type", "Destination", "RW", "Propagation") == ["bind", "/input", false, "rprivate"]
        supervisor_mount = mounts.find { |mount| mount["Destination"] == "/supervisor.py" }
        expected_mount &&= supervisor_mount && same_mount_source?(supervisor_mount["Source"], supervisor) && supervisor_mount.values_at("Type", "RW", "Propagation") == ["bind", false, "rprivate"]
        if @network_policy
          relay = mounts.find { |mount| mount["Destination"] == "/relay" }
          asset = mounts.find { |mount| mount["Destination"] == "/helper.cjs" }
          expected_mount &&= mounts.length == 4 && relay && relay.values_at("Type", "Name", "RW") == ["volume", @network_policy.volume, false] &&
            asset && same_mount_source?(asset["Source"], helper) && asset.values_at("Type", "RW", "Propagation") == ["bind", false, "rprivate"]
        else
          expected_mount &&= mounts.length == 2
        end
        valid = expected_mount && host["NetworkMode"] == "none" && host["ReadonlyRootfs"] == true && host["Privileged"] == false &&
          [nil, "", "private"].include?(host["PidMode"]) && host["IpcMode"] == "private" &&
          (host["Devices"] || []).empty? && (host["DeviceRequests"] || []).empty? &&
          (host["VolumesFrom"] || []).empty? && (host["PortBindings"] || {}).empty? &&
          host["CapDrop"] == ["ALL"] && (host["CapAdd"] || []).map { |cap| cap.delete_prefix("CAP_") }.sort == %w[KILL SETGID SETUID] && host["SecurityOpt"] == ["no-new-privileges"] &&
          host["Memory"] == @limits["memory_bytes"] && host["MemorySwap"] == @limits["memory_bytes"] && host["PidsLimit"] == @limits["pids"] &&
          host["NanoCpus"] == (Float(@limits["cpus"]) * 1_000_000_000).to_i &&
          host["Tmpfs"] == {"/tmp" => "rw,noexec,nosuid,nodev,size=#{@limits["tmpfs_bytes"]},mode=1777", "/workspace" => workspace_tmpfs.split(":", 2).last, "/control" => control_tmpfs.split(":", 2).last} &&
          (host["Devices"] || []).empty? && (host["Binds"] || []).empty? &&
          config["User"] == "0:0" && config["WorkingDir"] == "/workspace" && config["Image"] == @image &&
          config["Entrypoint"] == ["/usr/bin/python3"] && config["Cmd"] == ["-I", "-S", "/supervisor.py", *argv] &&
          env.all? { |key, value| config.fetch("Env").include?("#{key}=#{value}") } &&
          config.fetch("Env").all? { |entry| allowed_image_env?(entry, env) } &&
          config.fetch("Env").map { |entry| entry.split("=", 2).first }.uniq.length == config.fetch("Env").length
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
        when "HOME"
          value == "/tmp/home"
        when "XDG_CONFIG_HOME"
          value == "/tmp/config"
        when "XDG_DATA_HOME"
          value == "/tmp/data"
        when "XDG_CACHE_HOME"
          value == "/tmp/cache"
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

      def copy_tree!(source, destination, timeout:, cancellation:, deadline: nil)
        raise BoundaryError, "descriptor-relative copying unavailable: Fiddle dependency required" unless DescriptorFS.respond_to?(:openat)
        expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(timeout)
        bytes = 0
        entries = 0
        check = lambda do
          deadline&.check!(phase: "workspace copy")
          raise BoundaryError, "workspace copy cancelled" if cancellation&.cancelled?
          raise BoundaryError, "workspace copy deadline exceeded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= expires_at
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
            path = relative.empty? ? name : File.join(relative, name)
            raise BoundaryError, "workspace depth limit exceeded" if path.count("/") >= @limits.fetch("workspace_depth", 64)
            output = File.join(destination, path)
            fd = DescriptorFS.openat(directory.fileno, name, File::RDONLY | File::NOFOLLOW | File::NONBLOCK, 0)
            raise BoundaryError, "unsafe workspace/export entry: #{path}" if fd < 0
            file = IO.for_fd(fd)
            begin
              stat = file.stat
              raise BoundaryError, "privileged workspace mode: #{path}" unless (stat.mode & 0o7000).zero?
              if stat.directory?
                Dir.mkdir(output, 0o777)
                File.chmod(0o777, output)
                manifest << [path, "directory", stat.mode & 0o777]
                walk.call(file, path)
                check.call
                File.chmod(stat.mode & 0o777, output)
              elsif stat.file? && stat.nlink == 1
                File.open(output, File::WRONLY | File::CREAT | File::EXCL, (stat.mode & 0o111 == 0) ? 0o666 : 0o777) do |target|
                  while (chunk = file.read(65_536))
                    bytes += chunk.bytesize
                    check.call
                    target.write(chunk)
                  end
                end
                after = file.stat
                raise BoundaryError, "workspace file changed during copy: #{path}" unless [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime, stat.nlink, stat.mode] == [after.dev, after.ino, after.size, after.mtime, after.ctime, after.nlink, after.mode]
                File.chmod(stat.mode & 0o777, output)
                manifest << [path, "file", Digest::SHA256.file(output).hexdigest, stat.mode & 0o777]
              else
                raise BoundaryError, "unsafe workspace/export entry: #{path}"
              end
            ensure
              file.close
            end
          end
        end
        File.open(source, File::RDONLY | File::NOFOLLOW) do |directory|
          raise BoundaryError, "privileged workspace root mode" unless (directory.stat.mode & 0o7000).zero?
          manifest << ["", "directory", directory.stat.mode & 0o777]
          walk.call(directory, "")
          check.call
          File.chmod(directory.stat.mode & 0o777, destination)
        end
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
