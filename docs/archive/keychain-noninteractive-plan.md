# atomic編集のKeychain待ち修理

2026-09-10。工場担当から、公開0.6.0の6ファイル編集が300秒でtransport timeoutとなり、
結果が確定しない問題を受領した。所有範囲はAIShellだけ。

PID 35816の2回のsampleで、service初期化中の`SecItemCopyMatching`が停止点と確認した。
`ApplyChangeSetState`生成・bootstrap・applyManagedより前。TERMで終了しなかったためKILLし、
`ps`で消滅を確認。要求の遅延実行は停止した。対象6ファイルの差分は工場担当のapply_patchによるもの。

修理はmacOSの既存file-based Keychainに対する非対話操作と、実測で見つかった状態保存先の正規化。鍵の保存先、ACL、暗号化、
既存鍵を変更しない。Security APIが認証を要求する場合はtyped errorと当該要求の適用前中止を返す。
focused試験、MCP実測、release gate、公開、公開版smokeまで行う。工場のファイルは変更しない。

## 修理と検証の経緯

修理commit `0209f9a4883c58c23d31ee590ad1c23e46227eed` をmainへpushした。
Keychain方針1件、atomic編集wire7件、旧互換store14件のfocused試験と文書検査が成功。
[CI](https://github.com/kitepon/aishell/actions/runs/34418082684)のMac全体試験・配布検証も成功。
修正版MCPは同じ対象の鍵取得失敗を524msで返し、`request_status: aborted_before_side_effect`、
空の`changed_paths`を確認した。

このMacの既定Keychainは`SecKeychainGetStatus`がflags=2（unlock bitなし）を返した。
6ファイル正常系の実バイナリ試験は鍵の新規保存が-25293で即時失敗し、適用前中止を返した。
これは正常系成功とは数えない。その後、既定Keychainのunlock bitをAPIで確認した。
ただし同じMac上のCIが既定Keychainを一時切替するため、この値をlogin Keychainの状態とは断定できない。
解除後の実バイナリ試験では状態保存の`contentMismatch`を検出した。
台帳の保存先は`/tmp`へ正規化されるが、旧世代検索では`/private/tmp`の生パスと比較していた。
そのため同じ保存先の2世代がmaterializedのまま残り、旧世代のSHA検査で失敗した。
保存先を台帳と同じ正規形へ揃えた。wire正常系を`/private/tmp`で実行し、修正前の同一失敗と
修正後のwire7件成功を確認した。
修正commit `660e3209bf85eae123416be739508ba31a613e9e` をmainへpushした。
修正版debugバイナリの6ファイルMCP実操作は3938msでcommittedとなり、全内容一致を確認した。
配布package検証は成功したが、配布バイナリの6ファイル試験はKeychain書込み-25293で適用前中止となった。
npmの認証完了取得に失敗して公開を中断した後、同日夜にログインと公開認証を完了した。

## 公開後受入（完了）

2026-09-10、npmの0.6.1公開と公式global installが成功した。
公開commitは`cd1ea1ff33165c34ee3acc74c0b460ec83f92948`、配布SHA1は
`272271ebef4f6c86fd55f8bbac14d916da79e03e`。registryのversion・gitHead・SHA1が一致した。
[追加修正のCI](https://github.com/kitepon/aishell/actions/runs/34419127668)はMac全体試験と配布検証が成功した。
[GitHub Release](https://github.com/kitepon/aishell/releases/tag/v0.6.1)を同じ公開commitで作成した。

このMac（macOS 26.6.1 / arm64）で`npm install -g @quolu/aishell@0.6.1`、
`aishell-setup`、`aishell-setup --check`を実行し、すべて終了コード0だった。
Claude・Codex・Grok・Cursorの4登録で0.6.1の起動と`workspace_snapshot`のMCP実操作が成功した。
管理アプリはready、登録はCodexだけ更新され、他3件は変更不要だった。

公式install後のbare `aishell-mcp`を使い、独立した一時workspaceの6ファイルを
SHA条件付きで一括更新した。3043msで`committed`となり、全6ファイルの保存内容が一致した。
これは公開候補の結果ではなく、npm公開物を導入した後の実測である。
工場向け`factory_diagnostics`もreadyで問題0件だった。依頼された修理と公開後受入を完了した。
