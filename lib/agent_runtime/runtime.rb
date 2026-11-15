require "timeout"

module AgentRuntime
  class Runtime
    def initialize(store:, executors: {})
      @store = store
      @executors = {"fake" => Adapters::Fake.new}.merge(executors.transform_keys(&:to_s))
    end

    def run(ir, inputs: {}, workspace: nil, concurrency: 2, cancellation: nil)
      ir = Compiler.validate!(JSON.parse(IR.dump(ir)))
      raise Error, "concurrency must be 1..32" unless concurrency.is_a?(Integer) && concurrency.between?(1, 32)
      cancellation ||= Cancellation.new
      run_id = SecureRandom.uuid
      workspace ||= File.join(@store.root, "workspaces", run_id)
      FileUtils.mkdir_p(workspace)
      report = {"run_id" => run_id, "status" => "running", "ir_digest" => IR.digest(ir), "started_at" => Time.now.utc.iso8601(6), "steps" => {}, "outputs" => {}}
      @store.save_report(report)
      bindings = {}
      inputs = inputs.transform_keys(&:to_s)
      ir["inputs"].each do |name, type|
        raise Error, "missing required input #{name}" unless inputs.key?(name)
        bindings[name] = @store.put(type: type, value: inputs[name], run_id: run_id, step_id: "input", attempt: 0)
      end
      pending = ir["steps"].dup
      active = {}
      completions = Queue.new
      until pending.empty? && active.empty?
        pending.dup.each do |step|
          break if active.size >= concurrency
          dependencies = step["needs"]
          next unless dependencies.all? { |id| report["steps"].key?(id) }
          pending.delete(step)
          if cancellation.cancelled? || dependencies.any? { |id| report["steps"][id]["status"] != "success" }
            report["steps"][step["id"]] = {"status" => "cancelled", "attempts" => [], "error" => "cancelled or dependency failed"}
            next
          end
          snapshot = bindings.dup
          active[step["id"]] = Thread.new do
            result = execute_step(ir, step, snapshot, workspace, run_id, cancellation)
            completions << [step, result]
          rescue => e
            completions << [step, {"status" => "failure", "attempts" => [], "outputs" => {}, "error" => {"classification" => "runtime", "message" => e.message}}]
          end
        end
        unless active.empty?
          step, result = completions.pop
          active.delete(step["id"]).join
          report["steps"][step["id"]] = result
          result.fetch("outputs", {}).each { |name, artifact| bindings["#{step["id"]}.#{name}"] = artifact }
        end
        @store.save_report(report)
      end
      statuses = report["steps"].values.map { |s| s["status"] }
      report["status"] = %w[unknown timeout blocked failure cancelled].find { |s| statuses.include?(s) } || (cancellation.cancelled? ? "cancelled" : "success")
      if report["status"] == "success"
        ir["outputs"].each { |name, ref| report["outputs"][name] = bindings.fetch(ref) }
      end
      report["ended_at"] = Time.now.utc.iso8601(6)
      @store.save_report(report)
    rescue => e
      if report
        report["status"] = "failure"
        report["error"] = {"classification" => "runtime", "message" => e.message}
        report["ended_at"] = Time.now.utc.iso8601(6)
        @store.save_report(report)
      else
        raise
      end
    end

    private

    def adapter(name)
      return @executors[name] if @executors.key?(name)
      case name
      when "shell"
        require_relative "adapters/shell"
        @executors[name] = Adapters::Shell.new
      when "opencode"
        require_relative "adapters/opencode_cli"
        @executors[name] = Adapters::OpenCodeCLI.new
      else raise Error, "unknown executor adapter #{name}"
      end
    end

    def execute_step(ir, step, bindings, workspace, run_id, cancellation)
      attempts = []
      outputs = {}
      executor = ir["executors"].fetch(step["executor"])
      config = executor.fetch("config", {}).merge(step.fetch("config", {}))
      (step["retries"] + 1).times do |index|
        break if index.positive? && cancellation.cancelled?
        attempt = index + 1
        directory = File.join(workspace, step["id"], attempt.to_s)
        FileUtils.mkdir_p(directory)
        input_artifacts = step["inputs"].transform_values { |ref| bindings.fetch(ref) }
        values = input_artifacts.to_h do |name, artifact|
          value = @store.value(artifact)
          if %w[repository directory].include?(artifact["type"])
            destination = File.join(directory, "inputs", name)
            Store.materialize(Store.manifest(value), destination)
            value = destination
          elsif artifact["type"] == "file"
            destination = File.join(directory, "inputs", name)
            FileUtils.mkdir_p(File.dirname(destination))
            FileUtils.cp(value, destination)
            File.chmod(0o644, destination)
            value = destination
          end
          [name, value]
        end
        request = Request.new(run_id: run_id, step_id: step["id"], attempt: attempt, inputs: values, config: config, workspace: directory, timeout: step["timeout"], cancellation: cancellation)
        @store.save_attempt(run_id, step["id"], attempt, {"attempt" => attempt, "status" => "running", "started_at" => Time.now.utc.iso8601(6)})
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          selected_adapter = adapter(executor["adapter"])
          grace = selected_adapter.respond_to?(:timeout_cleanup_grace) ? selected_adapter.timeout_cleanup_grace : 0.1
          result = Timeout.timeout(step["timeout"] + grace) do
            selected_adapter.execute(request) do |decision|
              @store.save_attempt(run_id, step["id"], attempt,
                {"attempt" => attempt, "status" => "running", "admission" => decision})
            end
          end
          raise Error, "executor returned invalid result" unless result.is_a?(Result) && %w[success failure cancelled timeout unknown blocked].include?(result.status)
        rescue Timeout::Error
          result = Result.new(status: "timeout", outputs: {}, error: {"classification" => "timeout"})
        rescue => e
          result = Result.new(status: "failure", outputs: {}, error: {"classification" => "executor", "message" => e.message})
        end
        data = {"attempt" => attempt, "status" => result.status, "error" => result.error, "duration" => result.duration || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, "usage" => result.usage, "cost" => result.cost, "session_id" => result.session_id, "model" => result.model}
        if result.logs
          data["log"] = @store.put(type: "text", value: result.logs.is_a?(String) ? result.logs : JSON.generate(result.logs), run_id: run_id, step_id: step["id"], attempt: attempt)
        end
        if result.logs.is_a?(Hash) && result.logs["execution"].is_a?(Hash)
          data["execution"] = JSON.parse(JSON.generate(result.logs["execution"].except("events", "requests", "raw", "stdout", "stderr", "process", "frozen_config")))
          data["execution"]["evidence"] = data["log"] if data["log"]
        end
        if result.status != "success" && config["preserve_partial_outputs"] == true
          data["partial_outputs"] = {}
          step["outputs"].each do |name, type|
            next unless type == "repository" && result.outputs&.key?(name)
            begin
              data["partial_outputs"][name] = @store.put(type: type, value: result.outputs.fetch(name), run_id: run_id, step_id: step["id"], attempt: attempt, inputs: input_artifacts.values.map { |a| a["id"] }, metadata: {"partial" => true})
            rescue => error
              (data["partial_capture_errors"] ||= {})[name] = "#{error.class}: #{error.message}"
            end
          end
        end
        if result.status == "success"
          begin
            outputs = step["outputs"].to_h do |name, type|
              raise Error, "missing required output #{name}" unless result.outputs&.key?(name)
              [name, @store.put(type: type, value: result.outputs[name], run_id: run_id, step_id: step["id"], attempt: attempt, inputs: input_artifacts.values.map { |a| a["id"] })]
            end
          rescue => e
            data["status"] = "failure"
            data["error"] = {"classification" => "output_validation", "message" => e.message}
            outputs = {}
          end
        end
        attempts << data
        @store.save_attempt(run_id, step["id"], attempt, data)
        # Transport classification alone cannot establish that replay is safe.
        break unless data["status"] == "failure" && data["error"].is_a?(Hash) && data.dig("error", "classification") == "transport" && result.retry_safe == true && index < step["retries"] && !cancellation.cancelled?
      end
      {"status" => attempts.last["status"], "attempts" => attempts, "outputs" => outputs}
    end
  end
end
