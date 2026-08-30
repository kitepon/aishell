# AIShell 0.4.3

AIShell 0.4.3 fixes a workspace scan that failed completely when the project contained a single
file it could not read.

## Fixed

- `workspace_snapshot` no longer fails wholesale because of one unreadable entry. Two distinct
  causes are addressed.

  Sockets, FIFOs, and device nodes are no longer treated as workspace entries. They carry no
  content, so hashing them threw and the error propagated out of the directory walk, aborting the
  entire snapshot with `INTERNAL_ERROR: The file "…" couldn't be opened.` Any project containing
  a unix socket — for example a tool that keeps a daemon endpoint inside the repository — could
  not be snapshotted at all. These entries are now skipped the same way symbolic links already
  were.

  A regular file whose content cannot be read no longer aborts the scan either. The entry is kept
  with its path, size, and modification time, and only `sha256` is omitted — the same shape
  already used for files above the 4 MiB hashing limit. The failure stays observable as a missing
  hash rather than being hidden or fatal.

## Compatibility

No public surface changes. The tool catalog, schemas, and output shapes are unchanged: 7 tools by
default, 11 with `AISHELL_CAPABILITY_SET=expanded-v1`, 25 with `AISHELL_TOOL_PROFILE=full` or
`legacy`, and 1 with `AISHELL_TOOL_PROFILE=factory`.

Snapshots of projects that previously failed will now succeed. Projects that already worked are
unaffected, except that special files — which could never have been hashed — no longer appear as
entries.

## How this was found

The 0.4.2 read-only lane runs `workspace_snapshot` and `search_context` concurrently for the first
time, so that path was probed against a real installation to confirm the parallel journal
semantics held. The probe could not get a baseline snapshot of the AIShell repository itself,
because `.lattice/sensor/daemon.sock` aborted the scan. The defect predates 0.4.2 and is unrelated
to lane separation: it reproduces on a single request with nothing else in flight.
