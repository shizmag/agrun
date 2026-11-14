require_relative "test_helper"
require_relative "support/m01_harness"

class M01AcceptanceTest < Minitest::Test
  M01Harness::ACCEPTANCE.each_key do |id|
    define_method("test_#{id.tr(".-", "__")}") do
      in_tmp do |root|
        result = M01Harness.run(id, root: root)
        assert result["match"], JSON.pretty_generate(result)
      end
    end
  end
end
