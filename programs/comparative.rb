program :compositional_dsl do
  input :repository, type: :repository
  executor :agent, via: :opencode
  step :planner, with: :agent, inputs: {repository: "repository"},
    outputs: {repository: :repository, plan: :text}, config: {role: "planner"}, timeout: 120
  step :inventory, with: :agent, inputs: {repository: "repository"},
    outputs: {inventory: :text}, config: {role: "inventory"}, timeout: 120
  step :coder, with: :agent, inputs: {repository: "planner.repository", plan: "planner.plan", inventory: "inventory.inventory"},
    input_types: {repository: :repository, plan: :text, inventory: :text},
    outputs: {repository: :repository, implementation: :text}, config: {role: "coder"}, timeout: 120
  step :validate, with: :agent, inputs: {repository: "coder.repository"},
    outputs: {repository: :repository, validation: :text}, config: {role: "validate"}, timeout: 120
  step :reviewer, with: :agent, inputs: {repository: "validate.repository", implementation: "coder.implementation", validation: "validate.validation"},
    input_types: {repository: :repository, implementation: :text, validation: :text},
    outputs: {repository: :repository}, config: {role: "reviewer"}, timeout: 120
  emit :repository, from: "reviewer.repository"
end
