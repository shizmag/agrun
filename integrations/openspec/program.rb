program :specification_input do
  input :specification, type: :text
  executor :fixture, via: :fake, config: {operation: :value, values: {receipt: "specification supplied explicitly; no authoring model invoked"}}
  step :read_specification, with: :fixture, inputs: {specification: :specification}, outputs: {receipt: :text}
  emit :receipt, from: "read_specification.receipt"
end
