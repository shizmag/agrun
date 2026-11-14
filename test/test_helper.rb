require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/agent_runtime"

class Minitest::Test
  def in_tmp
    Dir.mktmpdir("agent-runtime-test") { |dir| yield dir }
  end
end
