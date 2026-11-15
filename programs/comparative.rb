program :compositional_dsl do
  input :repository, type: :repository
  executor :agent, via: :opencode
  step :planner, with: :agent, inputs: {repository: "repository"},
    outputs: {repository: :repository, plan: :text}, config: {role: "planner"}, timeout: 120
  step :coder, with: :agent, inputs: {repository: "planner.repository", plan: "planner.plan"},
    input_types: {repository: :repository, plan: :text},
    outputs: {repository: :repository, implementation: :text}, config: {role: "coder"}, timeout: 120
  step :reviewer, with: :agent, inputs: {repository: "coder.repository", implementation: "coder.implementation"},
    input_types: {repository: :repository, implementation: :text},
    outputs: {repository: :repository}, config: {role: "reviewer"}, timeout: 120
  emit :repository, from: "reviewer.repository"
end
