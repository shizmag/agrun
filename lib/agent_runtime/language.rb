module AgentRuntime
  class Language
    def load(path)
      instance_eval(File.read(path), path, 1)
      raise Error, "file must declare one program" unless @ir
      Compiler.validate!(@ir)
    end

    def program(name, &block)
      raise Error, "duplicate program" if @ir
      @ir = {"schema_version" => 1, "name" => name.to_s, "inputs" => {}, "executors" => {}, "steps" => [], "outputs" => {}, "config" => {}}
      instance_eval(&block)
    end

    def input(name, type:)
      declare(@ir["inputs"], name, type.to_s)
    end

    def executor(name, via:, config: {})
      declare(@ir["executors"], name, {"adapter" => via.to_s, "config" => normalize(config)})
    end

    def step(name, with:, inputs:, outputs:, needs: [], config: {}, timeout: 60, retries: 0, input_types: {})
      @ir["steps"] << {"id" => name.to_s, "executor" => with.to_s, "inputs" => normalize(inputs), "outputs" => normalize(outputs), "needs" => needs.map(&:to_s), "config" => normalize(config), "timeout" => timeout, "retries" => retries, "input_types" => normalize(input_types)}
    end

    def emit(name, from:)
      declare(@ir["outputs"], name, from.to_s)
    end

    private

    def normalize(value)
      JSON.parse(JSON.generate(value))
    end

    def declare(hash, name, value)
      raise Error, "duplicate identifier #{name}" if hash.key?(name.to_s)
      hash[name.to_s] = value
    end
  end
end
