# AIShell 0.3.6

AIShell 0.3.6 makes `run_observe` report the terminal result state itself, completing the same
design correction that 0.3.5 applied to `apply_change_set`.

## Changed

- `run_observe` status/read/wait/cancel responses now include `exitCode`, `signal`, and
  `cancelAcknowledged` alongside `terminationCause`. The values are nil while a run is live;
  on terminal runs, `exitCode`/`signal` carry the natural-exit outcome and `cancelAcknowledged`
  states whether cancellation was the accepted terminal cause.

## Why

The observation surface collapsed the terminal cause to a label such as `"natural_exit"` while the
service internally held the exit code and cancellation acceptance. A caller observing a finished
run had to reconstruct the outcome from artifacts. A mutation or process tool should return the
state it produced — "this is what happened", not "done".

## Compatibility

- Tool catalog, schemas, and tool count are unchanged.
- All added fields are optional additions to existing responses.

## Upgrade

```sh
npm install -g @quolu/aishell@0.3.6
```
