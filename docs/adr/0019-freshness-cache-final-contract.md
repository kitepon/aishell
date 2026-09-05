# ADR 0019: run_check freshness cache最終契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-22
- Lattice task: `ACE-030`
- Control: `aishell-capability-expansion-20260721`

## Decision

freshness cacheはADR 0018のimmutable `RunCheckInvocationPlan`と解決済みordered stepだけを入力に取り、invocation、dispatch、
check選択、step DAGを所有・変更しない。`direct`は`cache: off`だけを受理し、それ以外は
`RUN_CHECK_CACHE_NOT_ALLOWED`、process 0件で拒否する。missやbinding不足時もinvocationをdirectへ変換しない。

### Binding

cache keyはplan/selection digest、ordered step IDに加え、各stepについて次をcanonical bytesで束縛する。

- resolved executableのcanonical path、device/inode、mode、content SHA、symlink chain
- ordered arguments。空要素、byte境界、順序を保存する
- working directoryとallowed rootのcanonical path、volume/device/inode identity
- unsetとemptyを区別した全effective environmentのkey/value digest。平文secretは保存・表示しない
- toolchain provider/version、raw probe SHA、SDK/runtime/architecture
- profile ID/digest、manifest/lockfile identity
- complete relevant-input closure、missing leaf、directory membership、content Merkle root
- workspace generation/cursorとroot identity

open-world directはcache対象にしない。profile/focused stepもbindingを完全に証明できない時は`ineligible`であり、空digest、
現在値による補完、mtime/sizeだけのfresh判定を禁止する。

### Modeとaggregate transaction

| mode / 条件 | 結果 | process |
|---|---|---:|
| `off` | cache storeを読まず全plan実行、state `disabled` | N |
| `prefer`、全step complete hit | failedを含め全resultを元のstateで再利用 | 0 |
| `prefer`、一件でもmiss/ineligible | selection/DAG不変のまま全planをuncached実行 | N |
| `only`、全step complete hit | 全resultを再利用 | 0 |
| `only`、miss/incomplete/expiredあり | `RUN_CHECK_CACHE_MISS`、部分成功なし | 0 |
| `refresh` | lookupせず全plan実行、再照合後に新entryをpublish | N |
| 観測したcache materialが破損 | `CACHE_CORRUPT` | 0 |

focused setのlookup/admissionはplan全体のall-or-none transactionである。部分hitを成功resultへ混ぜない。cache policyで
requested/planned ID、順序、DAG、selection digestを変えない。`off`はcache materialを観測しないため、未観測の破損を理由に
失敗させない。

### Immutable publication

admission直前にbinding receiptを確定し、terminal artifact確定後かつentry publication前にroot、workspace generation、profile、
toolchain、executable、relevant inputsを再観測する。実行期間中に変更があればentryをpublishせず`CONTENT_CHANGED`を返す。
terminal artifactは保持するが、旧keyにも現在keyにも保存しない。hit時も現在bindingを先に構成し、entryとexact照合する。

entryはwrite-once generationで、terminal normal exitのpassedとfailedだけを保存できる。signal、timeout、cancel、launch failure、
artifact failureは保存しない。同一keyの並行publishは既存payloadを上書きせず、同一payloadなら既存generationを参照し、
異なるpayloadはtyped conflictにする。refreshも既存entryを置換しない。payload/artifactを全てfsyncした後、index/manifestを
原子的にpublishする。quota不足は`CACHE_QUOTA_EXCEEDED`、publication失敗は`CACHE_STORE_FAILED`とし、検査成功を保存成功に
見せない。artifact、entry metadata、error、activity、debug descriptionへsecretを出さない。

expiry、artifact失効、quota evictionはentry単位で行い、advertised retention中のartifactを先に消さない。corruptionはmissへ
丸めたり自動削除したりせず`CACHE_CORRUPT`とする。selection/profile/set identity不一致は
`RUN_CHECK_SELECTION_STALE`、`only`のmiss/incomplete/expiredはstep別lookup evidence付き`RUN_CHECK_CACHE_MISS`へ統一する。

## Verification contract

- executable bytes/symlink、argv、cwd inode、effective env、toolchain probe、manifest/lockfile、input content、directory membershipを
  一つずつ変え、size/mtime復元、rename/add/delete、同path inode置換でもfalse-fresh 0を確認する。
- passedとnormal-exit failedのhitでprocess増加0、source run/artifact SHAと元stateを一致させる。
- focused部分hitでpreferは全plan再実行、onlyはprocess 0・部分成功0とする。
- 実行中input変更、変更後復元、toolchain/executable置換でpublication 0、`CONTENT_CHANGED`を確認する。
- TTL境界、artifact先行失効、quota eviction、並行同key publish、atomic commit failure、refresh非上書きを確認する。
- responseだけでなくentry、artifact、activity、errorのsecret非露出を確認する。
- ADR 0018の24直積fixtureを共有し18合法/6拒否を維持する。
- v1 directのexecutable/argv/cwd/env、timeout、retention、terminal分類、完全artifactをcharacterizationとして維持する。

## Consequences

ACE-031は上記false-fresh、corruption、quota、publication failureを安全網として固定し、ACE-034はcache serviceを共通planへ
統合する。cache都合でdirect fallback、focused集合変更、silent miss、partial successを実装しない。
