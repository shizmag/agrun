require "json"
require "digest"
require "fileutils"
require_relative "experiment_manifest"
require_relative "submission"
require_relative "reports"
require_relative "release_identity"

module AgentRuntime
  module Benchmarks
    # Coordinates existing execution/grading boundaries; never starts a provider
    # itself. The caller supplies a runner configured for its execution mode.
    class ComparativeExperiment
      SCHEMA = "agru-comparative-freeze-v1".freeze
      STRATEGIES = %w[opencode fixed-workflow comparative-dsl].freeze

      def initialize(store:, runner: nil)
        @store, @runner = store, runner
      end

      def run(manifest:, evidence_kind:, cancellation: nil, live_authorization: nil, execution_id: nil)
        raise ArgumentError, "runner required" unless @runner
        validate_evidence_kind!(evidence_kind)
        manifest = ExperimentManifest.new(manifest) unless manifest.is_a?(ExperimentManifest)
        validate_manifest_evidence!(manifest.data, evidence_kind)
        options = {manifest: manifest, cancellation: cancellation, live_authorization: live_authorization}
        options[:execution_id] = execution_id if execution_id
        result = @runner.run(**options)
        verify_regrades(experiment_id: result.fetch("run_id"), evidence_kind: evidence_kind)
      end

      # Regrades the stored submission, not the mutable solver workspace. A new
      # grading attempt is required even if the verdict agrees with the first.
      def verify_regrades(experiment_id:, evidence_kind:)
        raise ArgumentError, "runner required" unless @runner
        validate_evidence_kind!(evidence_kind)
        original = @store.report(experiment_id)
        validate_report_evidence!(original, evidence_kind)
        checks = original.fetch("cells").map do |cell|
          unless cell["submission"]
            next {"cell_id" => cell.fetch("id"), "status" => "unavailable", "reason" => "no persisted submission"}
          end
          Submission.new(store: @store).verify(cell.fetch("submission"))
          before = cell.fetch("grading_attempts", [])
          report = @runner.regrade(experiment_id: experiment_id, cell_id: cell.fetch("id"))
          current = report.fetch("cells").find { |row| row.fetch("id") == cell.fetch("id") }
          attempts = current.fetch("grading_attempts")
          unchanged = current.fetch("submission") == cell.fetch("submission") && current["attempt_id"] == cell["attempt_id"]
          independent = attempts.size == before.size + 1 && !before.map { |row| row.fetch("attempt_id") }.include?(attempts.last.fetch("attempt_id"))
          agreement = %w[execution_status score verdict protocol quality_basis].all? { |key| current[key] == cell[key] }
          binding = independent && grading_pair_valid?(current, before.last, attempts.last)
          {"cell_id" => cell.fetch("id"), "status" => (unchanged && independent && agreement && binding) ? "verified" : "mismatch",
           "submission_unchanged" => unchanged, "new_grading_attempt" => independent, "outcome_agrees" => agreement, "grading_binding_valid" => binding,
           "original_grading_attempt_id" => before.last&.fetch("attempt_id"), "regrade_attempt_id" => attempts.last.fetch("attempt_id")}
        end
        {"schema" => SCHEMA, "experiment_id" => experiment_id, "evidence_kind" => evidence_kind,
         "report_digest" => IR.digest(@store.report(experiment_id)),
         "provider_evidence" => evidence_kind == "live_provider", "checks" => checks,
         "verified" => !checks.empty? && checks.all? { |check| check["status"] == "verified" }}
      end

      # Export is additive and refuses to overwrite a prior freeze. It includes
      # artifact identities, not private repositories, credentials or procedures.
      def freeze(experiment_id:, destination:, verification:)
        raise ArgumentError, "verification experiment mismatch" unless verification.fetch("experiment_id") == experiment_id
        validate_evidence_kind!(verification.fetch("evidence_kind"))
        report = @store.report(experiment_id)
        raise ArgumentError, "verification is stale or unbound" unless verification.fetch("report_digest") == IR.digest(report)
        self.class.validate_verification!(report, verification)
        identities = report.fetch("cells").filter_map do |cell|
          next unless cell["submission"]
          artifact = Submission.new(store: @store).verify(cell.fetch("submission"))
          {"cell_id" => cell.fetch("id"), "submission_id" => artifact.fetch("id"), "submission_digest" => artifact.fetch("digest"), "repository_manifest" => Store.manifest(artifact.fetch("path"))}
        end
        payload = {"schema" => SCHEMA, "release_identity" => ReleaseIdentity.capture(root: File.expand_path("../../..", __dir__)), "report" => report, "summary" => Reports.new(store: @store).summary(experiment_id: experiment_id),
                   "verification" => verification, "submissions" => identities,
                   "strategy_stages" => {"opencode" => {"stages" => 1, "inference_stages" => 1},
                                         "fixed-workflow" => {"stages" => 3, "inference_stages" => 3},
                                         "comparative-dsl" => {"stages" => 5, "inference_stages" => 3}},
                   "limitations" => ["Digest verification establishes integrity, not authenticity.",
                     "Simulated relay evidence is not evidence of live provider quality.",
                     "Independent regrade means a separate grading attempt, not a separate grader implementation."]}
        payload["release_identity"] = report.fetch("execution_release_identity", payload.fetch("release_identity"))
        payload["frozen_contract"] = self.class.frozen_contract(report)
        payload["frozen_experiment_digest"] = IR.digest(payload.fetch("frozen_contract"))
        bytes = JSON.pretty_generate(payload) + "\n"
        destination = File.expand_path(destination)
        Dir.mkdir(destination)
        File.write(File.join(destination, "experiment.json"), bytes, mode: "wx")
        File.write(File.join(destination, "SHA256SUMS"), "#{Digest::SHA256.hexdigest(bytes)}  experiment.json\n", mode: "wx")
        {"path" => destination, "sha256" => Digest::SHA256.hexdigest(bytes), "verified" => verification.fetch("verified")}
      end

      def self.verify_freeze(path)
        bytes = File.binread(File.join(path, "experiment.json"))
        expected = File.read(File.join(path, "SHA256SUMS"))
        actual = Digest::SHA256.hexdigest(bytes)
        raise ArgumentError, "freeze digest mismatch" unless expected == "#{actual}  experiment.json\n"
        payload = JSON.parse(bytes)
        raise ArgumentError, "unsupported freeze schema" unless payload.fetch("schema") == SCHEMA
        verification = payload.fetch("verification")
        report = payload.fetch("report")
        if payload.key?("frozen_contract")
          raise ArgumentError, "frozen contract mismatch" unless payload["frozen_contract"] == frozen_contract(report) && payload["frozen_experiment_digest"] == IR.digest(payload["frozen_contract"])
        end
        raise ArgumentError, "freeze verification binding mismatch" unless verification.fetch("experiment_id") == report.fetch("run_id") && verification.fetch("report_digest") == IR.digest(report)
        validate_verification!(report, verification)
        submissions = payload.fetch("submissions")
        expected = report.fetch("cells").select { |cell| cell["submission"] }.to_h { |cell| [cell.fetch("id"), cell.fetch("submission")] }
        ids = submissions.map { |submission| submission.fetch("cell_id") }
        raise ArgumentError, "portable submission set mismatch" unless ids.uniq.length == ids.length && ids.sort == expected.keys.sort
        submissions.each do |submission|
          artifact = expected.fetch(submission.fetch("cell_id"))
          raise ArgumentError, "portable submission identity mismatch" unless submission.fetch("submission_id") == artifact.fetch("id") && submission.fetch("submission_digest") == artifact.fetch("digest")
          manifest = submission.fetch("repository_manifest")
          paths = manifest.map { |entry| entry.fetch("path") }
          raise ArgumentError, "duplicate portable submission path" unless paths.uniq.length == paths.length
          manifest.each do |entry|
            path = entry.fetch("path")
            raise ArgumentError, "invalid portable submission entry" unless entry.keys.sort == %w[content executable path] && [true, false].include?(entry["executable"])
            raise ArgumentError, "unsafe portable submission path" unless path.is_a?(String) && !path.empty? && !path.include?("\0") && !path.start_with?("/") && path.split("/", -1).none? { |part| ["", ".", "..", ".git"].include?(part) }
            entry.fetch("content").unpack1("m0")
          end
          raise ArgumentError, "portable submission digest mismatch" unless IR.digest(manifest) == submission.fetch("submission_digest")
        end
        {"integrity_verified" => true, "experiment_id" => payload.fetch("report").fetch("run_id"),
         "regrades_verified" => payload.fetch("verification").fetch("verified"),
         "evidence_kind" => payload.fetch("verification").fetch("evidence_kind"), "sha256" => actual}
      end

      def self.frozen_contract(report)
        cells = report.fetch("cells")
        order = report.fetch("schedule", {}).fetch("cell_order", []).map do |id|
          cell = cells.find { |candidate| candidate["id"] == id }
          cell&.slice("task_id", "solver_id", "model", "repetition")
        end
        bindings = cells.flat_map do |cell|
          cell.fetch("grading_attempts", []).map do |attempt|
            request = attempt.fetch("request")
            request.slice("task_id", "benchmark", "specification_digest", "limits", "audited_binding").merge("implementation_fingerprint" => attempt["implementation_fingerprint"])
          end
        end.uniq.sort_by { |binding| IR.digest(binding) }
         {"schema" => "agru-frozen-contract-v1", "manifest" => report.fetch("manifest").except("experiment_id"),
         "execution_release_identity" => report.fetch("execution_release_identity", {}).slice("content_digest", "files"),
          "schedule" => report.fetch("schedule", {}).except("cell_order").merge("ordered_cells" => order),
          "simulation" => report.fetch("simulation", {}).except("attempts"),
         "solver_configurations" => report.fetch("solver_configurations", {}), "grading_bindings" => bindings}
      end

      BINDINGS = %w[task_id benchmark specification_digest submission_id submission_digest procedure_digest environment_digest limits].freeze

      def self.grading_pair_valid?(cell, first, second)
        return false unless first.is_a?(Hash) && second.is_a?(Hash)
        return false unless first["attempt_id"].is_a?(String) && second["attempt_id"].is_a?(String) && first["attempt_id"] != second["attempt_id"]
        a, b = first["request"], second["request"]
        return false unless a.is_a?(Hash) && b.is_a?(Hash)
        a = a.merge(a.fetch("audited_binding", {}).slice("procedure_digest", "environment_digest"))
        b = b.merge(b.fetch("audited_binding", {}).slice("procedure_digest", "environment_digest"))
        return false unless BINDINGS.all? { |key| a.key?(key) && !a[key].nil? && a[key] == b[key] }
        return false unless a["task_id"] == cell["task_id"] && a["submission_id"] == cell.dig("submission", "id") && a["submission_digest"] == cell.dig("submission", "digest")
        fingerprint = first["implementation_fingerprint"]
        return false if fingerprint.nil? || fingerprint == {} || fingerprint != second["implementation_fingerprint"]
        return false unless first["execution_status"] == "success" && second["execution_status"] == "success"
        left, right = first["result"], second["result"]
        return false unless left.is_a?(Hash) && right.is_a?(Hash)
        %w[execution_status score verdict protocol quality_basis].all? { |key| left[key] == right[key] && right[key] == cell[key] }
      end

      def grading_pair_valid?(cell, first, second)
        self.class.grading_pair_valid?(cell, first, second)
      end

      def self.validate_verification!(report, verification)
        new(store: nil).validate_report_evidence!(report, verification.fetch("evidence_kind"))
        raise ArgumentError, "freeze verification binding mismatch" unless verification.fetch("experiment_id") == report.fetch("run_id") && verification.fetch("report_digest") == IR.digest(report)
        cells, checks = report.fetch("cells"), verification.fetch("checks")
        raise ArgumentError, "invalid grading checks" unless checks.is_a?(Array) && checks.size == cells.size && checks.map { |c| c.fetch("cell_id") }.uniq.size == cells.size
        statuses = cells.map do |cell|
          check = checks.find { |c| c["cell_id"] == cell["id"] }
          raise ArgumentError, "missing grading check" unless check
          if check["status"] == "verified"
            attempts = cell.fetch("grading_attempts", [])
            first = attempts.find { |a| a["attempt_id"] == check["original_grading_attempt_id"] }
            second = attempts.find { |a| a["attempt_id"] == check["regrade_attempt_id"] }
            valid = attempts.index(first) && attempts.index(second) && attempts.index(first) < attempts.index(second) && grading_pair_valid?(cell, first, second)
            raise ArgumentError, "invalid grading history" unless valid && %w[submission_unchanged new_grading_attempt outcome_agrees grading_binding_valid].all? { |key| check[key] == true }
            true
          else
            raise ArgumentError, "invalid grading status" unless %w[mismatch unavailable].include?(check["status"])
            false
          end
        end
        raise ArgumentError, "invalid verified claim" unless verification["verified"] == (!statuses.empty? && statuses.all?)
        raise ArgumentError, "invalid provider evidence claim" unless verification["provider_evidence"] == (verification["evidence_kind"] == "live_provider")
      end

      def validate_manifest_evidence!(manifest, kind)
        validate_evidence_kind!(kind)
        allowed = case manifest["execution_mode"]
        when "offline" then "offline_fixture"
        when "live" then "live_provider"
        end
        raise ArgumentError, "evidence kind unsupported by execution provenance" unless kind == allowed
      end

      def validate_report_evidence!(report, kind)
        if kind == "simulated_relay"
          simulation = report.fetch("simulation", {})
          valid = report.fetch("manifest")["execution_mode"] == "offline" &&
            report["evidence_kind"] == kind && simulation["transport"] == "controlled_https" &&
            simulation["paid_provider_calls"] == false &&
            simulation["image"].to_s.match?(/\Asha256:[a-f0-9]{64}\z/) &&
            simulation["attempts"].is_a?(Array) && !simulation["attempts"].empty? && simulation["attempts"].all? { |attempt| Digest::SHA256.hexdigest(attempt.fetch("relay_log")) == attempt["relay_log_sha256"] && attempt["relay_log"].include?(attempt.fetch("attempt_id")) && attempt["relay_log"].include?('"status":200') } &&
            report.fetch("solver_configurations").values.all? { |config| config["live"] == true }
          raise ArgumentError, "evidence kind unsupported by simulator provenance" unless valid
          return
        end
        validate_manifest_evidence!(report.fetch("manifest"), kind)
        configs = report.fetch("solver_configurations")
        valid = report.fetch("manifest").fetch("solver_ids").all? do |id|
          config = configs.fetch(id)
          (kind == "offline_fixture") ? config["provenance"] == "fixture" && config["live"] == false : config["live"] == true
        end
        raise ArgumentError, "evidence kind unsupported by solver provenance" unless valid
      end

      private

      def validate_evidence_kind!(kind)
        raise ArgumentError, "unknown evidence kind" unless %w[offline_fixture simulated_relay live_provider].include?(kind)
      end
    end
  end
end
