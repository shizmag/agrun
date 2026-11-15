module AgentRuntime
  module Adapters
    # Executes argv directly, never through an implicit shell. POSIX process groups
    # ensure cancellation reaches ordinary subprocess descendants as well.
    class ProcessRunner
      CAPTURE_LIMIT = 1_048_576
      CLEANUP_TIMEOUT = 0.5

      def call(argv:, cwd:, timeout:, cancellation: nil, env: {})
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        truncated = false
        stdout_truncated = false
        stderr_truncated = false
        killed = false
        completed = false
        cleanup = {"errors" => [], "reaped" => false}
        raise ArgumentError, "argv must be a nonempty array of strings" unless argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) && !arg.include?("\0") } && !argv.first.empty?
        limit = Float(timeout || 300)
        raise ArgumentError, "timeout must be positive and finite" unless limit.positive? && limit.finite?
        valid_env = env.is_a?(Hash) && env.all? { |key, value| key.is_a?(String) && (value.nil? || value.is_a?(String)) }
        raise ArgumentError, "env must map strings to strings or nil" unless valid_env
        return result("cancelled", "", "", nil, started) if cancellation&.cancelled?

        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = Process.spawn(env, [argv.first, argv.first], *argv.drop(1), chdir: cwd, in: File::NULL, out: out_w, err: err_w, pgroup: true, close_others: true)
        out_w.close
        err_w.close
        buffers = {out_r => +"".b, err_r => +"".b}
        readers = buffers.keys.dup
        status = nil
        forced = nil
        terminated_at = nil
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          unless forced
            forced = "cancelled" if cancellation&.cancelled?
            forced ||= "timeout" if now - started >= limit
            if forced
              signal_group("TERM", pid)
              terminated_at = now
            end
          end
          if terminated_at && !killed && now - terminated_at >= 0.2
            signal_group("KILL", pid)
            killed = true
            readers.each { |io| io.close unless io.closed? }
            readers.clear
          end
          ready = readers.empty? ? nil : IO.select(readers, nil, nil, 0.02)
          ready&.first&.each do |io|
            chunk = io.read_nonblock(16_384, exception: false)
            if chunk.nil?
              readers.delete(io)
              io.close
            elsif chunk != :wait_readable
              remaining = CAPTURE_LIMIT - buffers[io].bytesize
              truncated ||= chunk.bytesize > remaining
              stdout_truncated ||= io == out_r && chunk.bytesize > remaining
              stderr_truncated ||= io == err_r && chunk.bytesize > remaining
              buffers[io] << chunk.byteslice(0, remaining) if remaining.positive?
            end
          end
          unless status
            waited = Process.waitpid2(pid, Process::WNOHANG)
            status = waited.last if waited
          end
          break if status && readers.empty?
          sleep(0.01) if readers.empty?
        end
        completed = true
        response = result(forced || (status.success? ? "success" : "failure"), buffers[out_r], buffers[err_r], status.exitstatus, started, truncated, stdout_truncated, stderr_truncated)
      rescue SystemCallError => error
        response = result("failure", "", error.message, nil, started, truncated, stdout_truncated, stderr_truncated)
      ensure
        interrupted = $!
        Thread.handle_interrupt(Exception => :never) do
          if pid
            # Reaping the leader does not establish completion: descendants
            # may still own inherited pipes in the same process group.
            begin
              waited = Process.waitpid2(pid, Process::WNOHANG) unless status
              status = waited.last if waited
            rescue Errno::ECHILD
              cleanup["reaped"] = true
            end
            unless completed || killed
              begin
                signal_group("KILL", pid)
              rescue SystemCallError => error
                cleanup["errors"] << {"operation" => "kill", "class" => error.class.name, "message" => error.message}
              end
            end
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLEANUP_TIMEOUT
            until status || cleanup["reaped"]
              begin
                waited = Process.waitpid2(pid, Process::WNOHANG)
                status = waited.last if waited
              rescue Errno::ECHILD
                cleanup["reaped"] = true
              end
              break if status || cleanup["reaped"]
              if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                cleanup["errors"] << {"operation" => "reap", "message" => "cleanup deadline exceeded"}
                break
              end
              sleep(0.01)
            end
            cleanup["reaped"] ||= !status.nil?
          end
        rescue SystemCallError => error
          cleanup["errors"] << {"operation" => "reap", "class" => error.class.name, "message" => error.message}
        ensure
          [out_r, out_w, err_r, err_w].compact.each do |io|
            io.close unless io.closed?
          rescue IOError, SystemCallError => error
            cleanup["errors"] << {"operation" => "close", "class" => error.class.name, "message" => error.message}
          end
          response["cleanup"] = cleanup if response
          interrupted&.instance_variable_set(:@process_cleanup, cleanup)
        end
      end

      private

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end

      def result(status, stdout, stderr, exit_code, started, truncated = false, stdout_truncated = false, stderr_truncated = false)
        {"status" => status, "stdout" => stdout.dup.force_encoding(Encoding::UTF_8).scrub,
         "stderr" => stderr.dup.force_encoding(Encoding::UTF_8).scrub, "exit_code" => exit_code, "truncated" => truncated,
         "stdout_truncated" => stdout_truncated, "stderr_truncated" => stderr_truncated,
         "duration" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started}
      end
    end
  end
end
