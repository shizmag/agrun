# Evaluator-owned procedure. This file must never enter a solver workspace.
require "json"
begin
  require File.join(ENV.fetch("TARGET_REPOSITORY"), "lib/clamp")

  cases = [[-2, 0, 10, 0], [20, 0, 10, 10], [4, 0, 10, 4], [0, 0, 10, 0],
    [10, 0, 10, 10], [-9, -5, -1, -5], [2.5, 0.5, 2.0, 2.0], [7, 3, 3, 3]]
  failures = cases.filter_map do |value, minimum, maximum, expected|
    actual = Clamp.call(value, minimum, maximum)
    "#{[value, minimum, maximum].inspect}: expected #{expected}, got #{actual.inspect}" unless actual == expected
  end
  begin
    Clamp.call(1, 5, 2)
    failures << "inverted bounds must raise ArgumentError"
  rescue ArgumentError
    # Expected.
  end
  puts failures.empty? ? "all hidden checks passed" : failures.join("\n")
  puts "AGRU_VERDICT=" + JSON.generate({"verdict" => failures.empty? ? "pass" : "fail"})
  exit(failures.empty? ? 0 : 1)
rescue StandardError, ScriptError => error
  warn "grader error: #{error.class}: #{error.message}"
  exit 2
end
