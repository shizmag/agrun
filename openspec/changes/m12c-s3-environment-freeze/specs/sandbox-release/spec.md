## ADDED Requirements

### Requirement: Installed auxiliary controls have valid positive calibration
The release SHALL pair each disabled plugin and LSP observation with a working
enabled control using the same installed binary, image, workspace, trigger and
observation mechanism, differing only in necessary feature configuration.

#### Scenario: Enabled sentinel is silent
- **WHEN** an enabled control fails to demonstrate the subsystem's execution
- **THEN** its disabled negative SHALL NOT count as proof of disablement

### Requirement: Experimental environment is immutable and reproducible
The release SHALL bind execution-affecting components and scientific protocol in
a content-addressed manifest after implementation and mandatory gates pass.

#### Scenario: Runtime changes after freeze
- **WHEN** runtime content or a bound configuration changes after freezing
- **THEN** validation SHALL reject the old freeze before execution

#### Scenario: Offline comparative acceptance
- **WHEN** an accepted freeze is exercised
- **THEN** all three distinct architectures SHALL execute with equivalent public
  inputs and boundary conditions and preserve immutable graded and regraded artifacts
- **AND** fixture results SHALL NOT be represented as live model performance
