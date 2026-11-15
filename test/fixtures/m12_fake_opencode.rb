#!/usr/bin/env ruby
# Offline protocol simulator: synthetic records, never a provider/session client.
require "json"

scenario = ENV.fetch("M12_SCENARIO", "success")
if ARGV.include?("--version")
  puts "opencode v2.3.0"
  exit
end
if ARGV.include?("--help")
  puts "Synthetic OpenCode: run --format json --standalone --model --session --agent"
  exit
end

session = "ses_synthetic"
emit = lambda do |type, payload = {}|
  puts JSON.generate({"type" => type, "timestamp" => 1_700_000_000_000, "sessionID" => session}.merge(payload))
  $stdout.flush
end
finish = lambda do |message = "msg_one", cost = 0.125|
  {"id" => "prt_#{message}", "sessionID" => session, "messageID" => message,
   "type" => "step-finish", "reason" => "stop", "cost" => cost,
   "tokens" => {"input" => 10, "output" => 3, "reasoning" => 2, "cache" => {"read" => 4, "write" => 1}}}
end

case scenario
when "malformed"
  puts "{broken"
when "nonobject"
  puts "[]"
when "empty"
  # Deliberately no protocol output.
when "text_only"
  emit.call("text", {"part" => {"id" => "prt_text", "sessionID" => session, "messageID" => "msg_one", "type" => "text", "text" => "hello"}})
when "partial"
  print '{"type":"step_finish"'
when "hang"
  emit.call("step_finish", {"part" => finish.call})
  sleep 60
else
  emit.call("step_start", {"part" => {"id" => "prt_start", "sessionID" => session, "messageID" => "msg_one", "type" => "step-start"}})
  if scenario == "tools"
    emit.call("tool_use", {"part" => {"partID" => "prt_tool", "id" => "call_one", "sessionID" => session, "messageID" => "msg_one", "type" => "tool", "tool" => "shell", "state" => {"status" => "error", "input" => {"command" => "false"}, "error" => "exit 1", "metadata" => {}, "time" => {"start" => 1, "end" => 2}}}})
  end
  if scenario == "retry_background"
    emit.call("retry", {"messageID" => "msg_one", "attempt" => 1, "nextRetryAt" => 2, "error" => {"type" => "transport", "message" => "synthetic retry"}})
    emit.call("background_wait", {"jobs" => [{"id" => "job_one", "kind" => "subagent", "title" => "synthetic"}]})
  end
  emit.call("step_finish", {"part" => finish.call})
  case scenario
  when "multiple"
    emit.call("step_finish", {"part" => finish.call("msg_two")})
  when "duplicate"
    emit.call("step_finish", {"part" => finish.call})
  when "conflict"
    emit.call("step_finish", {"part" => finish.call("msg_one", 0.25)})
  when "error"
    emit.call("error", {"error" => {"type" => "unknown", "message" => "synthetic execution failure"}})
  when "foreign"
    part = finish.call("msg_two")
    part["sessionID"] = "ses_foreign"
    emit.call("step_finish", {"part" => part})
  when "unknown"
    emit.call("future_extension", {"data" => {"value" => 7}})
  when "sensitive"
    emit.call("future_extension", {"data" => {"api_key" => "synthetic-secret-not-a-real-key"}})
  end
  exit 7 if scenario == "nonzero"
end
