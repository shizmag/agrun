require_relative "sandbox_deadline"

module AgentRuntime
  module Execution
    # Binary transport only: archive structure/terminators are validated by the
    # export parser. A failed result's partial file must never be published.
    class SandboxArchiveTransport
      STDERR_LIMIT = 16_384
      CLEANUP_TIMEOUT = 0.5
      TERM_GRACE = 0.1

      def call(argv:, cwd:, path:, deadline:, max_bytes:)
        raise ArgumentError, "max_bytes must be a positive integer" unless max_bytes.is_a?(Integer) && max_bytes.positive?
        raise ArgumentError, "argv must be nonempty strings" unless argv.is_a?(Array) && !argv.empty? && argv.all? { |v| v.is_a?(String) && !v.empty? && !v.include?("\0") }
        result = {"status" => "failure", "bytes" => 0, "stderr" => +"".b, "stderr_truncated" => false,
                  "cleanup" => {"reaped" => false, "errors" => []}}
        readers = []
        out_w = err_w = pid = status = nil
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          deadline.check!(phase: "export")
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe
          readers = [out_r, err_r]
          clean = ENV.keys.to_h { |key| [key, nil] }
          clean["PATH"] = ENV.fetch("PATH", "/usr/bin:/bin")
          pid = Process.spawn(clean, [argv.first, argv.first], *argv.drop(1), chdir: cwd,
            in: File::NULL, out: out_w, err: err_w, pgroup: true, close_others: true)
          out_w.close
          err_w.close
          until readers.empty? && status
            wait = [deadline.remaining!(phase: "export"), 0.02].min
            ready = readers.empty? ? (IO.select(nil, nil, nil, wait)
                                      []) : IO.select(readers, nil, nil, wait)&.first || []
            ready.each do |io|
              chunk = io.read_nonblock(65_536, exception: false)
              if chunk.nil?
                readers.delete(io)
                io.close
              elsif chunk != :wait_readable
                if io == out_r
                  if result["bytes"] + chunk.bytesize > max_bytes
                    result["error"] = "archive byte limit exceeded"
                    raise IOError, result["error"]
                  end
                  file.write(chunk)
                  result["bytes"] += chunk.bytesize
                else
                  remaining = STDERR_LIMIT - result["stderr"].bytesize
                  result["stderr"] << chunk.byteslice(0, remaining)
                  result["stderr_truncated"] ||= chunk.bytesize > remaining
                end
              end
            end
            unless status
              pair = Process.waitpid2(pid, Process::WNOHANG)
              status = pair.last if pair
            end
          end
          result["cleanup"]["reaped"] = true
          result["exit_code"] = status.exitstatus
          deadline.check!(phase: "export")
          result["status"] = status.success? ? "success" : "failure"
        end
        result
      rescue SandboxDeadline::Exceeded => e
        result["status"] = e.status
        result["error"] = e.message
        result
      rescue SystemCallError, IOError => e
        result["error"] ||= e.message
        result
      ensure
        [out_w, err_w, *readers].compact.each { |io| io.close unless io.closed? }
        if pid && !result.dig("cleanup", "reaped")
          cleanup_process(pid, result["cleanup"])
        end
      end

      private

      def cleanup_process(pid, report)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        signal_group("TERM", pid, report)
        killed = false
        loop do
          begin
            report["reaped"] = true if Process.waitpid(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            report["reaped"] = true
          end
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          if !killed && elapsed >= TERM_GRACE
            signal_group("KILL", pid, report)
            killed = true
          end
          break if killed && report["reaped"]
          break if elapsed >= CLEANUP_TIMEOUT
          IO.select(nil, nil, nil, 0.01)
        end
        report["errors"] << "archive subprocess not reaped within cleanup budget" unless report["reaped"]
        report["duration"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        report["timeout"] = CLEANUP_TIMEOUT
      end

      def signal_group(signal, pid, report)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      rescue SystemCallError => e
        report["errors"] << "#{signal}: #{e.message}"
      end
    end
  end
end
