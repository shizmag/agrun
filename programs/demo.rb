program :demo do
  input :repository, type: :repository
  executor :developer, via: :fake, config: {
    "operation" => "patch",
    "files" => {"lib/clamp.rb" => <<~RUBY}
      module Clamp
        def self.call(value, minimum, maximum)
          raise ArgumentError, "inverted bounds" if minimum > maximum
          [[value, minimum].max, maximum].min
        end
      end
    RUBY
  }
  step :implement, with: :developer, inputs: {repository: :repository}, outputs: {repository: :repository, patch: :patch}
  executor :public_check, via: :shell, config: {argv: [RbConfig.ruby, "--disable-gems", "-Ilib", "-rclamp", "-e", 'raise "public smoke check failed" unless Clamp.call(12, 0, 10) == 10; puts "public smoke passed"']}
  step :check, with: :public_check, inputs: {repository: "implement.repository"}, input_types: {repository: :repository}, outputs: {stdout: :text}, timeout: 10
  emit :repository, from: "implement.repository"
  emit :patch, from: "implement.patch"
  emit :public_check, from: "check.stdout"
end
