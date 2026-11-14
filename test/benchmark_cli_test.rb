require_relative "test_helper"
require_relative "../lib/agent_runtime/cli"
require "open3"

class BenchmarkCLITest < Minitest::Test
  def cli(*args)
    Open3.capture3(RbConfig.ruby, File.expand_path("../bin/agru", __dir__), "bench", *args)
  end

  def test_doctor_is_offline_and_declares_official_validation
    out, err, status = cli("doctor")
    assert status.success?, err
    data = JSON.parse(out)
    assert_equal true, data.fetch("offline_default")
    assert_equal "blocked", data.fetch("official_validation")
    assert_includes data.fetch("limitations").join(" "), "collector"
  end

  def test_fixture_plan_is_explicit_and_deterministic
    out, err, status = cli("plan", "experiments/fixture-infrastructure-smoke.json")
    assert status.success?, err
    plan = JSON.parse(out)
    assert_equal 16, plan.fetch("cells").size
    assert_equal 16, plan.fetch("cells").map { |cell| cell.fetch("id") }.uniq.size
    assert plan.fetch("cells").all? { |cell| cell.fetch("status") == "not_started" }
    again, = cli("plan", "experiments/fixture-infrastructure-smoke.json")
    assert_equal out, again
  end

  def test_unknown_commands_fail_instead_of_claiming_success
    _out, err, status = cli("not-a-command")
    refute status.success?
    assert_includes err, "unknown benchmark command"
  end

  def test_official_verification_is_not_a_fixture_pass
    out, _err, status = cli("verify", "nl2repo", "--offline")
    refute status.success?
    evidence = JSON.parse(out)
    assert_equal "blocked", evidence.fetch("status")
    assert_nil evidence.fetch("score")
    assert evidence.fetch("controls").values.all? { |control| control.fetch("status") == "blocked" }
  end

  def test_offline_run_report_and_regrade_are_persisted
    Dir.mktmpdir("benchmark-cli") do |directory|
      root = File.join(directory, ".agru")
      out, err, status = cli("run", "experiments/fixture-infrastructure-smoke.json", "--offline", "--root", root)
      assert status.success?, err
      experiment = JSON.parse(out)
      assert_equal 16, experiment.fetch("cells").size
      id = experiment.fetch("id")
      report, err, status = cli("report", id, "--root", root)
      assert status.success?, err
      assert_equal id, JSON.parse(report).fetch("experiment_id")
      csv, err, status = cli("report", id, "--format", "csv", "--root", root)
      assert status.success?, err
      assert_includes csv.lines.first, "task_id"
      markdown, err, status = cli("report", id, "--format", "markdown", "--root", root)
      assert status.success?, err
      assert_includes markdown, "infrastructure"
      cell = experiment.fetch("cells").first
      result, err, status = cli("regrade", id, cell.fetch("id"), "--root", root)
      assert status.success?, err
      assert_equal "completed", JSON.parse(result).fetch("status")
    end
  end
end
