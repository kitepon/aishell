# workspace snapshot再取得の実測（2026-09-13）

対象はMac上のAIShell実repo。`entry_limit: 5`、`context_budget: 1800`、project profileなし、branch diffのbaseは`17d56c1642643099e669fe079ce2645cd2009afc^`、patchなし、diff予算3500byteで固定した。出力上限を変えてscanを省略する操作は行っていない。

## 原因と変更

1. directory変更の展開で、通知ごとに全entryを検索し、重なったdirectoryの子孫を再列挙していた。照合batchごとのidentity・親子索引と訪問済み集合を使い、各directoryの直下を一度だけ列挙する。
2. 同processのfull snapshotは、通知の有無に関係なく全scanと内容hashを繰り返していた。前回の全件照合位置から通知が連続して残る場合、保持済みentryへ変更箇所の実ファイル照合を適用する。full要求の新generationとrestart用watermarkを維持する。
3. 削除通知の物理パスをFoundationが解決できず、監視対象外として捨てていた。存在する親でfirmlinkを解決し、削除済み末尾を戻して照合する。実FSEventsで削除通知が届くことと、この正規化前後の差を実測した。
4. restart時のsampleでは全entryのmetadata照合中に、同じfile/rootのパス正規化を繰り返していた。個々のentryで解決したパスを境界判定と相対path生成に再利用する。filesystem列挙、identity・size・mtimeの照合は残す。

新しい永続cacheや閾値は導入していない。稼働中observerがない場合、前回照合位置のgenerationが変わった場合、通知欠落、未照合通知のretention超過では、従来どおり全件再構築する。deltaの5000entry境界は維持し、明示full要求は全変更を照合する。

## 修正前の観測

以下はdirectory展開だけを先行修理したdebug buildでの計測で、通常fullの全scanは0.7.5と同じ経路だった。公開release buildとの速度比較には使わない。

| 条件 | 所要時間 | 全entry数 |
|---|---:|---:|
| cold | 55.700秒 | 198,511 |
| 無変更warm | 54.197秒 | 198,511 |
| 2file変更warm | 54.823秒 | 198,511 |

別実行で3秒間sampleを採取した際も、cold 53.076秒、無変更warm 52.977秒、2file変更warm 53.051秒だった。両warmのstackは`workspaceSnapshot → snapshot → scan → currentEntry → SHA-256`で、Git処理に到達する前の全域再読取りが主因だった。

restartの最初の測定は27.245秒（198,508entry）。内容hashを再利用しており、同process warmとは異なるmetadata再照合の経路を通っていた。

20万件の未変更索引と実在64fileのdirectory変更を使うfocused測定では、64件すべてを保持したまま6.6687秒から1.9364秒になった。このfixtureは変更範囲外だけが合成索引であり、cold scanやprovider tokenの測定ではない。

## 再現方法

```sh
node benchmarks/workspace-snapshot-warm.mjs /absolute/path/to/aishell-mcp /tmp/aishell-snapshot-warm.json
```

対象repoを静止させて実行する。scriptは所有する一時directoryと2fileを作成し、同じ要求でcold、無変更warm、2file変更warm、checkpointからのrestartを測る。各回の全entry数、返却5件、`fresh`を検査し、一時directoryだけを終了時に削除する。stateと結果はrepo外へ保存する。変更する2file以外の入力とOS負荷を厳密に隔離した実験ではなく、時間は実機の観測値として扱う。

## 最終候補の検証

関連47試験が成功した。無変更warmではscan回数と内容read回数が増えない。実FSEventsによる削除、nested directory rename、同size同mtime書戻し、observer無しの再構築、未照合通知のretention超過、restart後のcursor継続、5,001個のhard linkへの変更を確認した。MCPのschemaではcheckpointStateは従来からstringであり、tool数は増やしていない。

[最終候補の測定JSON](workspace-snapshot-warm-candidate.json)は0.7.6のdebug build。各回198,515entry、返却5件、freshを保持した。先行測定とのentry数差は追加した試験・benchmark・文書による。

| 条件 | 最終候補 |
|---|---:|
| cold | 48.348秒 |
| 無変更warm | 7.703秒 |
| 2file変更warm | 7.992秒 |
| restart | 21.408秒 |

checkpointはdelta適用途中でも保存され、全件照合位置を永続化していない。このためrestartではfilesystemのmetadataを照合して基点を確立し、以後の同process再取得では全scanを反復しない。無変更内容のhash再利用はfocused testで確認した。時間はprovider token削減率を表さない。

## 公開版の受入

0.7.6をmainの`2d489732d21827a51216f2965a3ce73577d21399`から公開した。npmのgitHeadは同じcommit。
[CI](https://github.com/kitepon/aishell/actions/runs/34713818366)と
[公開workflow](https://github.com/kitepon/aishell/actions/runs/34714133996)は成功し、
[GitHub Release](https://github.com/kitepon/aishell/releases/tag/v0.7.6)を作成した。

`npm install -g @quolu/aishell@latest && aishell-setup`でMacを更新した。Claude・Codex・Grok・Cursorは登録変更なしで、全4hostが0.7.6、11tools、hostVerified、ready、workspace_snapshot成功となった。

[公開版の測定と受入JSON](workspace-snapshot-warm-public.json)はnpmから導入したrelease buildを標準コマンドで新規起動した結果。全回198,516entry、返却5件、freshを保持した。

| 条件 | 公開0.7.6 | checkpointState |
|---|---:|---|
| cold | 44.923秒 | missing |
| 無変更warm | 6.043秒 | reconciled |
| 2file変更warm | 6.176秒 | reconciled |
| restart | 18.335秒 | restored |

修正前のdebug buildとの速度比を製品効果量として主張しない。coldの初回全件読取りとrestartのmetadata照合は実施しており、同process warmの全域scan反復を解消した。

公開版の実MCPで、削除、nested directory rename、同size同mtime書戻しのSHA、restart後のcursor継続、restart後の削除deltaを確認した。実dotagentsを読み取るsmokeでは、指定したsnapshot本文2件、3file読取り14,999byte、行80–110、誤った期待SHAへのCONTENT_CHANGED、検索周辺コード8block・13,485/14,000byteが成功した。元のdotagentsには書き込んでいない。

新規MCPプロセスでの受入は完了した。起動済みの長寿命MCPには、AI hostが再接続してから新版が適用される。
