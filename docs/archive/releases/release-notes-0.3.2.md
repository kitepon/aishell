# AIShell 0.3.2 release notes

Date: 2026-07-19

AIShell 0.3.2 makes the five-tool macOS runtime ready for a public OSS repository without changing its runtime behavior.

## Added

- English primary README and complete Japanese README with a 30-second setup, comparison table, architecture diagram, execution boundaries, and current limitations.
- Generated 1280×640 repository artwork, deterministic CoreGraphics renderer, and optimized Social preview asset.
- GitHub Actions CI on the public M1 arm64 `macos-15` runner for Swift tests, app packaging, and npm payload inspection.
- Contribution guide, private security-reporting policy, structured bug and feature forms, and a pull-request template.
- Apache License 2.0 with matching npm package metadata.
- Repository topics, npm homepage, and private vulnerability reporting.

## Corrected

- Public release history now distinguishes the shipped 0.3.0 `factory_diagnostics` release from the five-tool runtime that first shipped in 0.3.1.
- 0.3.0 and 0.3.1 release notes now describe their actual npm packages and Git commits.
- The 0.3.1 GitHub tag is anchored to npm `gitHead` `20ef0ce8fb6ef6551e42e64c6240977d7c28339d`.

## Unchanged

- The default profile remains `workspace_snapshot`, `read_context`, `search_context`, `run_check`, and `artifact_read`.
- `AISHELL_TOOL_PROFILE=full` retains the 25-tool compatibility surface.
- Process execution, allowed-root behavior, result schemas, benchmark evidence, and known runtime limits are unchanged from 0.3.1.
