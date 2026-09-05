# Security policy

## Supported versions

Security fixes are applied to the latest published release. Older experimental releases are not maintained separately.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use **Security → Report a vulnerability** on the GitHub repository to submit a private report. Include:

- the affected AIShell and macOS versions;
- 再現に必要なmacOSアクセス権、対象パス、MCP起動ディレクトリ、停止状態;
- minimal reproduction steps;
- the observed impact;
- whether the issue requires an allowed worker or child process.

AIShellは操作対象フォルダの登録や許可一覧を持たず、macOSのアクセス権で操作できるパスを受け付ける。相対パスはMCP起動ディレクトリを基準にする。

shellのbasename拒否は直接実行の設計を維持するための制約であり、sandboxや任意コード実行の安全境界ではない。停止、SHA競合検出、操作ごとのworkspace・cursor束縛、内部transaction領域の保護に反する挙動は、通常のworkerが持つファイル更新・子process起動・network accessの能力と区別して報告する。

The maintainer will acknowledge a complete report as soon as practical and coordinate disclosure after a fix or documented resolution is available.
