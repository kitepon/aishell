# AIShell 0.3.5

AIShell 0.3.5 makes `apply_change_set` report the state it produced, so a caller can confirm and
restate exactly what was written without a follow-up read.

## Changed

- `apply_change_set` now returns `after_content` for every applied change whose resulting file is
  UTF-8 text of 4 KiB or less. Larger files and binary content keep their existing `after_sha256`
  and complete diff artifact, so responses stay token-lean.
- The per-change `result` field is removed. A committed transaction implies every listed change was
  applied, so the field duplicated `status` while reading like the outcome of the call. Each change
  now reports only its resulting state: `after_path`, `after_sha256`, `after_content`, sizes, and
  metadata.

## Correctness

- The resulting content is preserved across recovery and replay paths, so a replayed transaction
  reports the same state as the original commit.
- The tool catalog and output schemas are unchanged; `changes` remains a generic array, so the
  frozen tool-catalog digest is identical to 0.3.4.

## Why

A mutation tool differs from a read tool: its success is a side effect, and the answer a caller
needs — what the files now contain — was not in the response. Callers had to volunteer that from
memory, and a redundant `"applied"` verdict string sat where the answer belonged. Returning the
resulting state, and removing the competing verdict, makes the outcome something the caller relays
rather than reconstructs.

## Upgrade

```sh
npm install -g @quolu/aishell@0.3.5
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- /opt/homebrew/bin/aishell-mcp
```
