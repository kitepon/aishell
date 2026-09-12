# AIShell npm配布判断

- 出典: [[raw/npm-publishing-2026]]
- 検証日: 2026-07-19、2026-09-06、2026-09-12追記
- 確度: 高（公式仕様 + registry実測）

## 初回採用構成の履歴

管理UIとlauncherを含む以下の構成は過去の記録。現行の導入手順は[製品契約](../docs/setup.md)を参照する。

- 公開名: `@quolu/aishell`
- 対応: macOS arm64、macOS 15以降
- `aishell-mcp`: npm `bin` からSwift製Mach-Oへ直接リンク
- `aishell-open`: package内の `AIShell.app` をLaunchServicesで開く明示コマンド
- `aishell-setup`: 管理アプリ準備、AI登録、読戻し、MCP実操作を一回で確認する明示コマンド。現行の導入・更新手順は[製品契約](../docs/setup.md)を正とする。
- lifecycle install script: 不採用（0.4.4で助言専用postinstallを試したが、0.4.5で撤回）

MCPと管理アプリの起動経路はどちらもinstall scriptに依存させない。インストール時にユーザー領域へ
アプリを自動コピーする副作用も作らない。

## install scriptを持てない実測理由（2026-07-25、npm 11.17.0）

0.4.4で `postinstall` を1本だけ足し、開いたままupgradeされた窓のpidを警告させた
（[[macos-app-upgrade-window-staleness]]）。**実installで走らなかった。**

```
npm install -g @quolu/aishell@0.4.4
→ changed 1 package in 536ms
   npm warn allow-scripts 1 package has install scripts not yet covered by allowScripts:
   npm warn allow-scripts   @quolu/aishell@0.4.4 (postinstall: node scripts/check-running-instances.mjs)
```

- `npm config get allow-scripts` は空（user/project設定に無く、**npmの既定挙動**）
- 「依存packageのscriptが既定offになる」のはnpm 12からと文書化されていたが、**npm 11.17.0の時点で
  globalに直接installする自package自身のscriptもblockされる**
- 結果、警告は既定で永久に出ないのに、`allow-scripts` 警告行だけが全installへ増える

前倒し通知としての価値が既定で0になり、コストだけが全利用者に残る。よって撤回した。開いたまま
upgradeされた窓の検知は、app側（`InstallationIntegrity`）だけを正とする。`verify-npm-package.mjs`
に「install系lifecycle scriptを持たない」ことのassertionを置いて、再発を機械gateで止める。

## 公開認証（2026-09-06確認）

- 出典: [npm公式変更告知](https://github.blog/changelog/2025-12-09-npm-classic-tokens-revoked-session-based-auth-and-cli-token-management-now-available/)、[Trusted publishing](https://docs.npmjs.com/trusted-publishers/)、[[raw/npm-session-auth-20260906]]。
- `npm login`は2時間のsessionを発行する。期限後は再ログインが必要で、session中の公開にも2FAが適用される。
- 0.5.0公開では保存認証がE401になり、ログイン完了後の公開にも別のWebAuthn認証が要求された。対話PTYから`--browser=false`で新しい認証URLを取得し、Chromeで認証して公開が成功した。出力リダイレクト時はEOTPで終了した。
- 信頼済み公開はOIDCでCIのidentityを検証し、公開用の長期tokenを不要にする方式。今回の公開は手動認証で実施した。
- 公開手順は[README](../README.md)、0.5.0の公開版検証は[ADR 0030](../docs/adr/0030-folder-registration-removal.md)を参照する。

## 手作業の公開認証を省く方法（2026-09-12確認）

- 出典: [npm Trusted Publishing公式仕様](https://docs.npmjs.com/trusted-publishers/)、[[raw/npm-trusted-publishing-20260912]]。
- npmに特定repositoryの公開workflowを登録すると、そのworkflowはOIDCによって自動認証できる。直接公開を許可したジョブでは、毎回のTouch ID操作と長期npm tokenを必要としない。
- GitHub ActionsはGitHub管理のrunnerを使う必要がある。既存のself-hosted runnerをそのまま公開元にはできない。
- 2026-09-03以降の新規設定ではstage公開が既定になる。毎回の承認を必要としない直接公開には、登録時に `npm publish` を許可する必要がある。
- 初回のnpm設定とworkflow追加は必要。この確認時点では提案だけで、AIShellの公開方式は変更していない。
- 0.7.2公開ではログインが有効でもWebAuthn認証が一度要求された。公開後のglobal install、4つのAIのsetup確認、編集・削除・工場診断では認証を要求されなかった。

## 初回配布時の実測（0.3.1の履歴）

- 公開・global install検証済み: `@quolu/aishell@0.3.1`、dist-tag `latest`
- registry shasum: `b6407da41c579a4a9e995bf8dc4654df43c05a07`
- global install先: `/opt/homebrew/lib/node_modules/@quolu/aishell`
- PATH: `/opt/homebrew/bin/aishell-mcp`、`/opt/homebrew/bin/aishell-open`
- npm導入後のhelperはdefault profileで高密度5 tool、`AISHELL_TOOL_PROFILE=full`で25 toolを公開
- npm導入後のMCP initializeはversion `0.3.1`を返却
- npm導入後のapp bundleでstrict deep code-signature検証成功
