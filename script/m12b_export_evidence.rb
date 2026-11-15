require "json"
require "digest"

# Input is JSON from the existing reconstructed benchmark report command.
# Never open Store here: exporting must not create, migrate, or repair run state.
module M12bExportEvidence
  IDENTIFIERS = %w[id run_id task_id solver_id model provider route execution_kind status execution_status verdict protocol quality_basis trust_scope availability outcome process_outcome artifact_status verification discrepancy observation_basis billing_status reported_cost_basis actual_charge_status currency provenance operation class type schema_version].freeze
  NUMBERS = %w[score expected collected executed passed failed skipped total repetition invocation_count observed_launch_count duration agent_duration grading_duration known_subtotal observed_count accepted_requests duplicate_observations conflicting_requests unidentified_observations identified_requests observations amount known_subtotal_amount].freeze
  BOOLEANS = %w[complete stream_complete operationally_complete session_reported_complete accounting_complete launch_observed reaped allowed].freeze
  CONTAINERS = %w[cells steps attempts execution identity requested observed accounting_coverage usage tokens input output reasoning cache_read cache_write coverage reported_cost estimate cost_evidence process_cleanup cleanup errors completion grading_attempts result metrics provenance manifest].freeze
  DIGESTS = %w[manifest_digest experiment_digest specification_digest procedure_digest environment_digest submission_digest report_sha256 executable_sha256 pricing_digest].freeze

  def self.project(value, key = nil)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |field, result|
        child = value[field]
        if DIGESTS.include?(field)
          result[field] = child if child.is_a?(String) && child.match?(/\A[0-9a-f]{64}\z/)
        elsif %w[evidence artifact_id].include?(field)
          result[field] = child if child.is_a?(String) && child.match?(/\A(?:sha256:)?[0-9a-f]{64}\z/)
        elsif CONTAINERS.include?(field)
          result[field] = project(child, field) if child.is_a?(Hash) || child.is_a?(Array)
        elsif key == "steps" && child.is_a?(Hash)
          result[field] = project(child) if safe_identifier?(field)
        elsif IDENTIFIERS.include?(field)
          result[field] = child if child.nil? || safe_identifier?(child)
        elsif NUMBERS.include?(field)
          result[field] = child if child.nil? || (child.is_a?(Numeric) && child.finite?)
        elsif BOOLEANS.include?(field)
          result[field] = child if child.nil? || child == true || child == false
        elsif key == "accounting_coverage"
          result[field] = child if %w[unknown partial native_step_observations not_provider_billing].include?(child)
        end
      end
    when Array
      value.filter_map { |child| project(child) if child.is_a?(Hash) }
    end
  end

  def self.safe_identifier?(value)
    value.is_a?(String) && value.length <= 160 && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.:+\/-]*\z/) && !value.start_with?("/", "http:", "https:") && !value.include?("..")
  end

  def self.export(report)
    raise ArgumentError, "expected a report object with cells" unless report.is_a?(Hash) && report["cells"].is_a?(Array)
    {"export_schema" => "m12b-scientific-evidence-v1", "qualification" => "sanitized persisted observations; not upstream billing or routing attestation",
     "source_json_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(report))), "report" => project(report)}
  end

  def self.canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |child| canonical(child) }
    else value
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: ruby script/m12b_export_evidence.rb RECONSTRUCTED_REPORT.json (sanitized JSON on stdout)" unless ARGV.length == 1
  puts JSON.pretty_generate(M12bExportEvidence.export(JSON.parse(File.read(ARGV.fetch(0)))))
end
