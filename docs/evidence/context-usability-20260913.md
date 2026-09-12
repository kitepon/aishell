# 検索・複数ファイル読取りの実測

取得日: 2026-09-13。対象: 公開0.7.4と公開0.7.5。これはJSON応答byte数の比較で、provider報告tokenや最適なモデル操作回数の比較ではない。

## 原因

- readは先頭から処理し、2件目以降が残り予算に丸ごと収まらなければ停止していた。予算を余らせ、後続実装の見渡しを妨げていた。
- searchは前後のコードをcontextBlocksに生成するが、MCP本文は一致行だけを出し、structuredContentからもblockのtextを除いていた。呼出し元がenvelopeを丸ごと表示することとは独立した本文欠落だった。
- query順・path順の連続出力により、一致が多いquery/fileが最初のページを占めていた。
- snapshotは大きい案内fileを予算不足で飛ばし、収まる古いテスト・隠しfileを拾っていた。調査意図の入力はなかった。

## 固定条件

読み取り元はdotagentsのcommit `aef57686331e2d677c74ddda39eec03ed8f3db48`。git archiveした内容を隔離directoryへ展開し、git initした同一fixtureを使った。元repoは変更していない。

対象は`PLAN.md`、`bin/setup-windows-native-factory.ps1`、`bin/agents-update.sh`。3ファイル連結のSHA-256は`8f6b49a0178a49a7a974e0a6009d0befd5ab5cf012abc97e1301572a2708fd4d`。
元の`bin/agents-update.ps1`は親が確認せず指定した存在しないpathであり、AIShellの不具合として数えていない。

再現scriptは[context-usability.mjs](../../benchmarks/context-usability.mjs)。binary、fixture、出力JSONを引数にする。
毎回同じsnapshotを1回取得した後、以下を測った。表の呼出し回数には共通のsnapshotを含めない。

- read: 1回の共有予算15,000 bytes。全3対象の先頭1,000文字（BOMを除く、合計4,540 bytes）を得るまで同じtargetsのcontinuationを読む。
- search: 1回14,000 bytes、max_results=2。Windows fileの`npm`と更新本体の`resolve_npm_global_bin()`を別queryにし、それぞれ最初の一致行・前2行・後3行（合計954 bytes）を得る。検索continuationを読み、周辺本文が届かない旧版では同じ2対象のreadを継続する。
- broad search: 元の広いregex、前2行・後3行、14,000 bytes、max_results=50を、上記の実在2実装fileに限定して1回呼ぶ。

## 比較

| 同じ必要本文の取得 | 0.7.4の呼出し | 修正後の呼出し | 0.7.4の総応答bytes | 修正後の総応答bytes |
|---|---:|---:|---:|---:|
| 3対象の先頭抜粋 | 5 | 1 | 67,812 | 16,815 |
| 2 queryの前後コード | 10 | 1 | 81,171 | 5,169 |

これは固定scriptの手順の改善であり、旧版を人が別の順序で使った場合の最小回数を主張しない。全ファイル全文の取得に必要な情報量が減ったという意味でもない。

| 広いregexを1回呼ぶ | 0.7.4 | 修正後 |
|---|---:|---:|
| contentのbytes | 1,566 | 4,543 |
| structuredContentのbytes | 11,129 | 10,555 |
| 総応答bytes | 12,744 | 15,147 |
| 返却match件数 | 15 | 13 |

広いregexでは周辺コードが本文に入り、総量は増えた。検索の予算超過はなく、未返却件数とcontinuationを保つ。位置・digest・cursor等のmetadataは消していない。
単純にenvelope全体を二度表示する呼出し元の重複は計測に含めず、MCP resultをJSONで一度直列化した量を総応答量とした。

[修正前JSON](context-usability-before.json)と[修正後JSON](context-usability-after.json)にcontent、structuredContent、総量を分けて保存した。

## 既定の改善と追加指定

予算分配、検索周辺コード本文、query/fileの交互表示は従来の引数のまま改善する。
Windows実装をsnapshotへ直接埋め込むには`context_paths`、特定部分だけ読むにはtarget objectの行範囲を指定する。
未知の意図を推測せず、既定snapshotは案内・構成・実装を優先する。元の古いテストと隠し管理fileは既定本文に入らなくなった。

上限が小さければ全対象の必要箇所が一度に入るとは限らない。長い周辺blockは既存のoversized descriptorを返す。
read continuationは全対象のSHAへ結びつき、UTF-8の欠落・重複なしで継続する。cursor・検索continuationの整合性、明示error、完全log/artifact保持は維持する。

## 公開後の受入

実装commitは`17d56c1642643099e669fe079ce2645cd2009afc`。通常CI `34711450334`と公開workflow `34711451874`は成功し、npm registryの0.7.5のgitHeadも一致した。
公開workflowが製品所有のrelease条件・build:npm・配布物検査を実行した。ローカルでは変更に直結する失敗再現、workspace/read/search/MCPの関連試験、公開文書の8検査が成功した。

このMacで公式npm更新とaishell-setupを実行し、Claude・Codex・Grok・Cursor全てが0.7.5、hostVerified/ready=true、workspace_snapshot成功となった。
公開aishell-mcpで本稿の固定比較を再実行し、表と同じ回数・応答量を再現した。修正後JSONはこの公開版の実測である。

実際のdotagentsでも、context_pathsでWindows setupとagents-update.shを選択し、3対象読取りは1回・14,999本文bytes、行80〜110の読取り、期待SHA不一致のCONTENT_CHANGED、広いregexの8周辺blockが本文に届くことを確認した。検索recordは13,485 bytesで14,000の上限内だった。
元repo、他製品の設定、Git除外設定は変更していない。今回の受入項目に未解決の不具合は残っていない。既存AIセッションのMCPは再接続すると新版へ切り替わる。

0.7.6で追加修理したsnapshot再取得の性能と公開後受入は[別の実測記録](workspace-snapshot-warm-20260913.md)に記載した。
