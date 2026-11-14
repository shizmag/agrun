# Run locally: mise exec -- ruby integrations/openspec/import_example.rb
# No model calls. Imports existing workflow text as an explicit DSL input.
require_relative "../../lib/agent_runtime"
require_relative "../../lib/agent_runtime/integrations/openspec"

store = AgentRuntime::Store.new(".agru/openspec-example")
integration = AgentRuntime::Integrations::OpenSpec.new(workspace: File.expand_path("../..", __dir__))
artifacts = integration.import_artifacts(change: "m0-runtime", store: store, run_id: "spec-import")
ir = AgentRuntime.compile(File.join(__dir__, "program.rb"))
report = AgentRuntime::Runtime.new(store: store).run(ir, inputs: {specification: store.value(artifacts.first)})
puts JSON.pretty_generate(report)
