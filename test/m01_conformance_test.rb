require_relative "test_helper"
require_relative "support/m01_harness"

class M01ConformanceTest < Minitest::Test
  M01Harness::CONFORMANCE.each_key do |id|
    define_method("test_#{id.tr(".-", "__")}") do
      in_tmp do |root|
        result = M01Harness.run(id, root: root)
        assert result["match"], JSON.pretty_generate(result)
      end
    end
  end
end
