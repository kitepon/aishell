# npm認証の公式資料抜粋

- 取得日: 2026-09-06（JST）
- 確度: 高（npm運営の公式資料）
- 形式: 取得したHTML本文からの短い原文抜粋。解釈と実測は[npm-distribution](../npm-distribution.md)に分離する。

## Session認証

- 出典: https://github.blog/changelog/2025-12-09-npm-classic-tokens-revoked-session-based-auth-and-cli-token-management-now-available/
- 公開日: 2025-12-09

> These sessions automatically expire after two hours, requiring reauthentication to continue publishing.

> During these sessions, 2FA is enforced for publishing operations

## 信頼済み公開

- 出典: https://docs.npmjs.com/trusted-publishers/
- 参照箇所: Trusted publishingの概要と設定手順。CIのOIDC連携を扱う。
