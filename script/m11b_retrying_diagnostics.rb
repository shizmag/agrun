# Local grading-only controls. Private tests never leave the image.
require "digest"
require "fileutils"
require "json"
require_relative "../lib/agent_runtime"
require_relative "../lib/agent_runtime/benchmarks/nl2repo_grader"

abort "explicit --allow-local-diagnostics required" unless ARGV == ["--allow-local-diagnostics"]
root = File.expand_path("../.agru/nl2repo/diagnostics", __dir__)
FileUtils.mkdir_p(root)
grader = AgentRuntime::Benchmarks::NL2RepoGrader.new
%w[untouched_image clean_empty clean_incorrect clean_reference_release].each do |control|
  setup = case control
  when "clean_reference_release"
    "mkdir -p /tmp/source /tmp/candidate /tmp/private; tar --no-same-owner -xzf /reference.tar.gz -C /tmp/source; cp /tmp/source/retrying-1.3.4/retrying.py /tmp/source/retrying-1.3.4/LICENSE /tmp/source/retrying-1.3.4/NOTICE /tmp/candidate/; cp /workspace/test_retrying.py /tmp/private/; cp /workspace/setup.py /workspace/requirements.txt /tmp/candidate/; cd /tmp/candidate"
  when "clean_empty"
    "mkdir -p /tmp/candidate /tmp/private; cp /workspace/test_retrying.py /tmp/private/; cp /workspace/setup.py /workspace/requirements.txt /tmp/candidate/; cd /tmp/candidate"
  when "clean_incorrect"
    "mkdir -p /tmp/candidate /tmp/private; cp /workspace/test_retrying.py /tmp/private/; cp /workspace/setup.py /workspace/requirements.txt /tmp/candidate/; printf 'def retry(*args, **kwargs):\\n    return lambda fn: fn\\n' > /tmp/candidate/retrying.py; cd /tmp/candidate"
  else
    "mkdir -p /tmp/baseline; cp /workspace/* /tmp/baseline/; cd /tmp/baseline"
  end
  tests = (control == "untouched_image") ? "test_retrying.py" : "/tmp/private/test_retrying.py"
  script = <<~SH
    #{setup}
    echo '=== artifact hashes ==='
    sha256sum /workspace/test_retrying.py /workspace/setup.py
    find . -maxdepth 1 -type f -exec sha256sum {} +
    echo '=== native install ==='
    PIP_NO_INDEX=1 PIP_DISABLE_PIP_VERSION_CHECK=1 pip install --no-build-isolation --prefix=/tmp/install -e .
    echo "INSTALL_EXIT=$?"
    echo '=== module origin ==='
    PYTHONPATH="$PWD" python -c 'import retrying,hashlib; print(retrying.__file__); print(hashlib.sha256(open(retrying.__file__, "rb").read()).hexdigest())'
    echo "IMPORT_EXIT=$?"
    echo '=== collect ==='
    PYTHONPATH="$PWD" pytest --collect-only -q -p no:cacheprovider #{tests}
    echo "COLLECT_EXIT=$?"
    echo '=== test ==='
    PYTHONPATH="$PWD" pytest --continue-on-collection-errors -vv -p no:cacheprovider #{tests}
    echo "TEST_EXIT=$?"
  SH
  reference = (control == "clean_reference_release") ? File.join(root, "../reference/retrying-1.3.4.tar.gz") : nil
  evidence = grader.diagnose(script: script, root: root, timeout: 120, reference_archive: reference)
  evidence.merge!("control" => control, "procedure_sha256" => Digest::SHA256.hexdigest(script),
    "declared_cases" => 23, "mode" => "clean_diagnostic_not_legacy", "reference_available" => !reference.nil?,
    "execution_status" => "unavailable", "score" => nil, "verdict" => nil,
    "limitations" => ["same-process observations untrusted", "writable tmp copy and prefix install differ from native layout", "release 1.3.4 reference is not proven identical to image 1.3.4-dev source"])
  File.write(File.join(root, "#{control}.json"), JSON.pretty_generate(evidence) + "\n", mode: "w", perm: 0o600)
  puts "#{control}: #{evidence.fetch("status")} (raw evidence persisted, no authoritative score)"
end
