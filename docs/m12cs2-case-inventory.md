# S2 actual-Docker case inventory

Mission source: `.agru/m12cs2-mission-context.txt:169-190`. This inventory
separates actual Docker evidence from helper/parser-only or pending evidence;
a repeated run is not a new case. A helper-only case exercises Docker but is
not by itself proof of the full runner-to-store flow. Status reflects the
independent review, not a claim that the complete gate is passed.

| # | Required case | Evidence / limitation | Status |
|---|---|---|---|
| 1 | Normal completion and export | `test/sandbox_boundary_test.rb` real host canary; successful integrated export | Docker integrated |
| 2 | Background writer after immediate exit | `test/m12cs2_integrated_adversarial_test.rb` background writer retains FD | Docker integrated |
| 3 | Detached late child | `test/m12cs2_integrated_adversarial_test.rb` detached writer | Docker integrated |
| 4 | Open-FD writer | integrated open-descriptor writer case | Docker integrated |
| 5 | Repeated modification during export | integrated attacker repeatedly writes until killed and reaped before export; exported content and digest remain stable. The invariant prevents a live attacker from writing during export; no claim of observed concurrent modification | Docker integrated: attack prevented |
| 6 | Refuses graceful termination | integrated term-refusing writer and supervisor detached term-resistant case | Docker integrated |
| 7 | Forced cleanup | supervisor forced kill/removal loses tmpfs; boundary timeout cleanup | Docker helper and integrated timeout |
| 8 | Export timeout | `test/m12c_sandbox_lifecycle_test.rb:test_timeout_during_real_docker_archive_stream_never_accepts_partial`; independently rerun lifecycle suite 6 runs/43 assertions | Docker integrated |
| 9 | Cancellation during quiescence | lifecycle cancellation on logs | Docker integrated |
| 10 | Container disappearance before export | lifecycle removes container on logs | Docker integrated |
| 11 | Tmpfs loss on stop | supervisor forced cleanup/restart-loss scenarios | Docker supervisor only |
| 12 | Executable mode | `test/sandbox_export_metadata_test.rb:test_real_docker_read_only_executable_export` asserts exported 0555 file | Docker integrated |
| 13 | Read-only mode | real-Docker metadata test asserts exported 0555 file and directory; `test/m12c_private_cleanup_test.rb` independently checks directory/content | Docker integrated |
| 14 | Privileged modes | `test/m12c_private_cleanup_test.rb` creates setuid file in Docker and asserts mode-specific rejection and no export | Docker integrated |
| 15 | Traversal / escaping symlink | integrated escaping symlink rejection plus parent-path escape probe in `test/m12cs2_integrated_adversarial_test.rb`; forged raw archive traversal remains parser-unit tested | Docker integrated path/symlink; raw archive unit only |
| 16 | Special objects | real malicious export FIFO case in boundary test | Docker integrated |
| 17 | Oversized / excessive outputs | real workspace tmpfs quota, control tmpfs exhaustion, and integrated excessive output entry rejection in `test/m12cs2_integrated_adversarial_test.rb` | Docker integrated |
| 18 | No accepted unsafe/incomplete export | real unsafe symlink/hardlink/FIFO rejected; actual Docker archive producer cut after 512 bytes is rejected with no export in `test/m12cs2_integrated_adversarial_test.rb` | Docker integrated |
| 19 | No false success from partial export | lifecycle cases reject absent export after cancellation/disappearance and real partial archive stream timeout | Docker integrated |
| 20 | Immutable store reverification | E parity evidence `.agru/m12cs2-parity-final-20261115/evidence.json`; three mode-preserving immutable submissions graded and regraded; E reports 1 run/55 assertions | Docker parity (E reported) |

Independent integrated read-only private staging cleanup passed actual Docker:
`test/m12c_private_cleanup_test.rb`, 1 run, 7 assertions, no failures/errors/skips;
it asserts staging disappearance and preserved exported mode/content.
