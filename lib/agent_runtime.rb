require "json"
require "digest"
require "fileutils"
require "securerandom"
require "time"
require "tmpdir"

module AgentRuntime
  VERSION = "0.1.0"
  class Error < StandardError; end
  Request = Struct.new(:run_id, :step_id, :attempt, :inputs, :config, :workspace, :timeout, :cancellation)
  Result = Struct.new(:status, :outputs, :error, :duration, :usage, :cost, :logs, :session_id, :model, :retry_safe)

  class Cancellation
    def initialize
      @mutex = Mutex.new
      @cancelled = false
    end

    def cancel!
      @mutex.synchronize { @cancelled = true }
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end
  end

  def self.compile(path)
    Language.new.load(path)
  end
end

require_relative "agent_runtime/ir"
require_relative "agent_runtime/execution/model_catalog"
require_relative "agent_runtime/language"
require_relative "agent_runtime/store"
require_relative "agent_runtime/adapters/fake"
require_relative "agent_runtime/runtime"

require_relative "agent_runtime/tracing/session"
