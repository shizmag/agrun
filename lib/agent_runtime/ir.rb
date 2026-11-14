module AgentRuntime
  module IR
    def self.normalize_json(value, ancestors = [])
      case value
      when Hash, Array
        raise Error, "malformed JSON data: circular value" if ancestors.any? { |entry| entry.equal?(value) }
        ancestors += [value]
        if value.is_a?(Array)
          value.map { |entry| normalize_json(entry, ancestors) }
        else
          value.each_with_object({}) do |(key, entry), result|
            raise Error, "malformed JSON object key" unless key.is_a?(String) || key.is_a?(Symbol)
            key = key.to_s
            raise Error, "duplicate normalized JSON key #{key}" if result.key?(key)
            result[key] = normalize_json(entry, ancestors)
          end
        end
      when Symbol then value.to_s
      when String, Integer, TrueClass, FalseClass, NilClass then value
      when Float
        raise Error, "malformed JSON number" unless value.finite?
        value
      else
        raise Error, "malformed JSON data: #{value.class}"
      end
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def self.dump(ir)
      JSON.generate(canonical(ir))
    end

    def self.digest(ir)
      Digest::SHA256.hexdigest(dump(ir))
    end
  end

  module Compiler
    TYPES = %w[text string integer number boolean json file directory repository patch evaluation_report].freeze

    def self.validate!(ir)
      raise Error, "malformed IR object" unless ir.is_a?(Hash)
      raise Error, "unsupported IR schema version" unless ir["schema_version"] == 1
      raise Error, "missing program identity" unless ir["name"].is_a?(String) && !ir["name"].empty?
      inputs, executors, steps = ir.values_at("inputs", "executors", "steps")
      raise Error, "malformed declarations" unless inputs.is_a?(Hash) && executors.is_a?(Hash) && steps.is_a?(Array)
      raise Error, "malformed final outputs" unless ir.fetch("outputs").is_a?(Hash)
      config!(ir) if ir.key?("config")
      executors.each_value do |executor|
        raise Error, "malformed executor declaration" unless executor.is_a?(Hash)
        adapter = executor["adapter"]
        raise Error, "malformed executor adapter" unless adapter.is_a?(String) && !adapter.empty?
        config!(executor) if executor.key?("config")
      end
      steps.each do |step|
        raise Error, "malformed step declaration" unless step.is_a?(Hash)
        %w[inputs outputs].each do |key|
          raise Error, "malformed step #{key}" unless step.fetch(key).is_a?(Hash)
        end
        raise Error, "malformed step input_types" unless step.fetch("input_types", {}).is_a?(Hash)
        needs = step.fetch("needs")
        raise Error, "malformed step needs" unless needs.is_a?(Array) && needs.all? { |dep| dep.is_a?(String) }
        config!(step) if step.key?("config")
      end
      names = steps.map { |s| s.fetch("id") }
      (inputs.keys + executors.keys + names + ir.fetch("outputs").keys).each { |name| identifier!(name) }
      raise Error, "duplicate step identifiers" unless names.uniq == names
      inputs.each_value { |type| type!(type) }
      types = inputs.dup
      steps.each do |step|
        raise Error, "missing executor #{step["executor"]}" unless executors.key?(step["executor"])
        raise Error, "missing required outputs for #{step["id"]}" if step.fetch("outputs").empty?
        step["outputs"].each do |name, type|
          identifier!(name)
          type!(type)
          types["#{step["id"]}.#{name}"] = type
        end
        timeout = step["timeout"]
        raise Error, "invalid limits" unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout > 0 && step["retries"].is_a?(Integer) && step["retries"].between?(0, 10)
      end
      steps.each do |step|
        step.fetch("inputs").each do |name, ref|
          identifier!(name)
          raise Error, "missing input or invalid output reference #{ref}" unless ref.is_a?(String) && types.key?(ref)
          expected = step.fetch("input_types", {})[name]
          type!(expected) if expected
          raise Error, "type mismatch for #{step["id"]}.#{name}" if expected && expected != types[ref]
        end
        inferred = step["inputs"].values.filter_map { |ref| ref.split(".").first if ref.include?(".") }
        step["needs"] = (step.fetch("needs") + inferred).uniq.sort
        step["needs"].each { |dep| raise Error, "missing dependency #{dep}" unless names.include?(dep) }
      end
      remaining = steps.to_h { |s| [s["id"], s["needs"].dup] }
      until remaining.empty?
        ready = remaining.select { |_, deps| deps.empty? }.keys
        raise Error, "dependency cycle: #{remaining.keys.join(", ")}" if ready.empty?
        ready.each { |id| remaining.delete(id) }
        remaining.each_value { |deps| deps.reject! { |id| ready.include?(id) } }
      end
      raise Error, "missing final outputs" if ir.fetch("outputs").empty?
      ir["outputs"].each_value { |ref| raise Error, "invalid final output reference #{ref}" unless ref.is_a?(String) && types.key?(ref) }
      JSON.generate(ir)
      ir
    rescue KeyError => e
      raise Error, "malformed IR: #{e.message}"
    end

    def self.config!(declaration)
      raise Error, "malformed config object" unless declaration["config"].is_a?(Hash)
      declaration["config"] = IR.normalize_json(declaration["config"])
    end

    def self.type!(type)
      raise Error, "invalid type #{type}" unless TYPES.include?(type)
    end

    def self.identifier!(name)
      raise Error, "invalid identifier #{name}" unless name.is_a?(String) && name.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
    end
  end
end
