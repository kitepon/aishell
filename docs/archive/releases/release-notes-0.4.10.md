# AIShell 0.4.10

AIShell 0.4.10 fixes a workspace-scale context preparation bottleneck found by fresh-host smoke testing after 0.4.9.

## Fixed

- Workspace context candidates now compute their priority exactly once per file before sorting.
- Relative workspace paths are classified with string operations instead of constructing filesystem-resolving `URL` values inside the sort comparator.
- Manifest and guidance-file classification use the same filesystem-free path-component logic.
- Cursor-free lexical search now restores a valid checkpoint and reconciles replayed FSEvents without performing the full filesystem metadata scan required by `workspace_snapshot`. Missing checkpoints and continuity-loss signals still take the explicit full-scan path.
- Lexical search no longer builds and sorts the complete indexed-file projection unless a glob query actually consumes it, and a zero context budget skips context-candidate preparation entirely.
- Git project-profile discovery now reads tracked and non-ignored untracked manifests with `git ls-files --cached --others --exclude-standard`; verified non-Git roots retain direct filesystem discovery, while Git command failures remain typed errors.
- Checkpoint loading validates canonical entry order without allocating path-component arrays and a duplicate-path set for every entry. Full payload SHA-256, schema, journal, and entry-invariant validation remain mandatory.

On the AIShell repository checkpoint containing 198,478 entries, the previous comparator repeatedly invoked current-directory and filesystem resolution during `O(n log n)` sorting, leaving fresh-host `search_context` CPU-bound for minutes. After removing the comparator amplification, unconditional full scan, unused indexed-file projection, and ignored-manifest traversal, the same release-mode cursor-free query completed in 5.94 seconds. The remaining cost is the mandatory integrity check of the existing 74 MB checkpoint, not a filesystem rescan.

## Compatibility

Tool names, schemas, profiles, search defaults, and result shapes are unchanged from 0.4.9.
