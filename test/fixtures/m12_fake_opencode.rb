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
  final_part = finish.call
  final_part.delete("tokens") if scenario == "missing_usage"
  final_part.delete("cost") if scenario == "missing_usage"
  emit.call("step_finish", {"part" => final_part})
  case scenario
  when "multiple"
    emit.call("step_finish", {"part" => finish.call("msg_two")})
  when "duplicate"
    emit.call("step_finish", {"part" => finish.call})
  when "conflict"
    emit.call("step_finish", {"part" => finish.call("msg_one", 0.25)})
  when "usage_conflict"
    conflicting = finish.call
    conflicting.fetch("tokens")["input"] = 999
    emit.call("step_finish", {"part" => conflicting})
  when "aggregate_conflict"
    # Explicit extension, not an audited native aggregate/reconciliation event.
    emit.call("synthetic_aggregate", {"data" => {"input" => 999}})
  when "model_mismatch"
    # Native CLI does not expose resolved model identity. This extension cannot
    # authorize pricing or prove an actual provider/model mismatch.
    emit.call("synthetic_model", {"data" => {"provider" => "other", "model" => "other"}})
  when "artifact_failure", "artifact_success"
    File.write("synthetic_partial_artifact.txt", "offline artifact\n")
    if scenario == "artifact_failure"
      emit.call("error", {"error" => {"type" => "unknown", "message" => "synthetic failure after artifact"}})
      exit 7
    end
  when "truncated"
    # ProcessRunner's bounded capture must mark this incomplete, even though
    # an otherwise valid finish appeared before the overflowing suffix.
    20_000.times { puts "x" * 1024 }
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
