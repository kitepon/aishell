# AIShell 0.4.8

AIShell 0.4.8 restores the expanded development tool catalog in Claude Code.

## Fixed

- Every tool in the default, `expanded-v1`, and factory profiles now declares top-level
  `type: object` input and output schemas. Claude Code previously rejected the entire
  `expanded-v1` catalog when union schemas omitted that declaration.
- A catalog regression test now covers both schema directions across the affected profiles.

## Compatibility

Tool names, union variants, request fields, and result fields are unchanged. The baseline
development catalog remains unchanged; only the missing top-level type declarations are added
to `expanded-v1` union schemas.

Verified with Claude Code 2.1.221 by loading a fresh user-configured session and calling
`mcp__aishell__runtime_status` successfully.
