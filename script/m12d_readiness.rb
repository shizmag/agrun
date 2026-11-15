require "json"

# Offline inspection only. This script has no dispatch or credential interface.
module M12dReadiness
  def self.blockers(plan)
    failures = []
    failures << "candidate_release_unbound" unless plan["candidate_release"].is_a?(Hash)
    failures << "transport_image_unbound" unless plan["transport_image"].is_a?(String) && plan["transport_image"].match?(/\Asha256:[0-9a-f]{64}\z/)
    %w[upstream_origin inference_configuration_digest].each do |key|
      failures << "provider_#{key}_unbound" if plan.fetch("provider")[key].nil?
    end
    %w[task_digest grader_digest].each do |key|
      failures << "benchmark_#{key}_unbound" if plan.fetch("benchmark")[key].nil?
    end
    gates = %w[reviewed_live_transport positive_negative_network_controls credential_separation deadline_and_quiescent_export request_session_accounting frozen_architecture_manifests independent_mock_parity grader_artifact_bindings resource_failure_controls independent_security_review operator_scope_authorization]
    gates.each { |gate| failures << gate unless plan.fetch("required_gates", {})[gate] == true }
    failures
  end
end

if $PROGRAM_NAME == __FILE__
  plan = JSON.parse(File.read(File.expand_path("../experiments/m12d-authorization-plan.json", __dir__)))
  blockers = M12dReadiness.blockers(plan)
  puts JSON.pretty_generate({status: blockers.empty? ? "REVIEW_REQUIRED" : "BLOCKED", blockers: blockers, dispatch_performed: false})
  exit(blockers.empty? ? 0 : 1)
end
