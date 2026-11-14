## 1. Core runtime
- [x] 1.1 Compile DSL and validate canonical typed artifact IR.
- [x] 1.2 Persist immutable artifact content, provenance, attempts and final reports (restart/resume is deferred).
- [x] 1.3 Exercise CLI and offline baseline runtime end to end.

## 2. Integration boundary
- [x] 2.1 Implement direct-argv process execution, bounded capture, deadlines and cancellation.
- [x] 2.2 Implement shell executor and explicit-live OpenCode V2 CLI executor.
- [x] 2.3 Implement optional local OpenSpec import, inspect and validate.
- [x] 2.4 Add offline local executable tests and integration documentation.
- [ ] 2.5 Run explicit authorized live OpenCode acceptance test with protocol/version capture.

## 3. Deferred integrations
- [ ] 3.1 Design and test V2 HTTP authentication, lifecycle and streaming cancellation.
- [ ] 3.2 Evaluate explicit Serena configuration separately from disabled baseline benchmark.
