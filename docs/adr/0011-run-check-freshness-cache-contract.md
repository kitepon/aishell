# ADR 0011: `run_check` freshness cache契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: superseded by ADR 0019
- Date: 2026-07-21
- Lattice task: `ACE-030`
- Control: `aishell-capability-expansion-20260721`

> このADRは翌日の[ADR 0019: run_check freshness cache最終契約](0019-freshness-cache-final-contract.md)に
> 置き換えられた。ACE-030の完了証拠もADR 0019である。実装契約としては参照しないこと。
> 主な相違: 本ADRは`freshness_cache`へ`off | prefer | only | refresh`の4 modeを持たせ、bindingを
> 完成できない`prefer`でも直接実行を許した。ADR 0019はADR 0018のimmutable `RunCheckInvocationPlan`と
> 解決済みordered stepだけを入力に取り、`direct`は`cache: off`だけを受理して他は
> `RUN_CHECK_CACHE_NOT_ALLOWED`でprocess 0件のまま拒否する。以下は当時の検討記録として残す。

## Context

現行`run_check`は、同じ検査を連続して要求されても毎回processを起動する。単純なcommand文字列だけをkeyにした
cacheは、実行binary、継承environment、toolchain、入力fileのどれかが変わった時に古い成功を返すため採用できない。
反対に、完全な実行条件と入力をmacOSの現在状態へ束縛できる検査まで常に再実行すると、反復開発でprocess起動、
artifact生成、model待機を減らせない。

freshness cacheは実行の代替backendではなく、過去の確定済みterminal resultが現在も同じ検査を表すことを証明して
再利用する経路である。証明できない時にも`run_check`本来の直接実行能力は維持するが、cache hitへ見せかけない。

## Decision

### 1. 公開境界と明示opt-in

`aishell.run-check.v2`へ省略可能な`freshness_cache` requestを追加する。省略時は`mode=off`であり、lookupも保存も
行わない。既存v1 requestは従来どおり直接実行する。cache利用は次の明示modeだけで許可する。

| Mode | lookup | miss時の実行 | terminal resultの保存 |
|---|---:|---:|---:|
| `off` | しない | する | しない |
| `prefer` | する | する | eligibleならする |
| `only` | する | しない | しない |
| `refresh` | しない | する | eligibleなら置換せず新entryとして保存 |

`freshness_cache`は`mode`に加え、project profileが発行した`check_id`と`profile_digest`を必須にする。
callerが任意commandへ「cache可能」という真偽値を付けるAPIは公開しない。`prefer`でbindingを完成できない場合は
直接実行できるが、resultを`cache.state=ineligible`、`reason`付きで返し、missやhitへ偽装しない。`only`では
`CACHE_BINDING_INCOMPLETE`又は`CACHE_MISS`で停止する。corruptionはmodeに関係なくfail closedとし、直接実行へ
fallbackしない。

resultは必ず`cache` objectを持ち、少なくとも`state`、`mode`、`eligible`、`reason`、`key_sha256`、
`source_run_id`、`created_at`、`expires_at`を返す。`state`は
`disabled | ineligible | miss_executed | refresh_executed | hit`のclosed setとする。hitでもrequestごとの新しい
`request_id`を発行し、元の`run_id`、元の実行時間、lookup時間を分離する。cache利用を通常の新規実行に見せない。

### 2. 完全binding key

cache keyは`aishell.check-cache-key.v1` canonical CBOR bytesのSHA-256とする。文字列連結やlocale依存JSONを
使わない。次のfieldを全て含み、一つでも取得不能ならkeyを作らない。

- cache key schema、`run_check` result schema、diagnostic parser／check adapter version。
- symlink解決後の実行fileのcanonical path、device/inode、mode、content SHA-256。PATH検索前の名前だけをkeyにしない。
- argumentの順序、空文字、byte境界を保存した配列。shell用の再結合文字列へ正規化しない。
- canonical working directoryのpath、device/inode、許可root identity。
- processへ実際に渡す継承値とoverrideをmergeした**全effective environment**の、key byte順canonical map digest。
  値はcache metadataやactivityへ平文保存せずdigestへだけ含める。unsetと空文字を区別する。
- project profileのschema、project root identity、`check_id`、profile digest、manifest／lockfile digest、target、
  check arguments template digest。
- toolchain provider、version probeのraw bytes SHA-256、SDK/runtime/architecture、resolved toolchain executable群と
  symlink chainのdigest。人向けversion文字列だけへ縮約しない。
- relevant input setの完全性receiptとMerkle root。leafはproject-relative path、file identity、kind、mode、
  content SHA-256を持ち、存在しない必須pathはmissing leaf、directoryは決定的な直下membership leafを持つ。
  rename、追加、削除、同size/mtime変更のいずれでもrootが変わるようにする。
- 検査結果へ影響する実行policy。timeout、locale、timezone、network policy、clock/randomness policy、
  deterministic seed、feature flagsを含む。

key作成はworkspace cursorと同じ観測transaction内で行い、入力hash前後のworkspace generation、root identity、
profile digest、toolchain digestを再照合する。途中で変化した場合は`CONTENT_CHANGED`で停止し、旧key、部分key、
前回profileへfallbackしない。TTLやmtimeだけをfreshness根拠にしない。

effective environment全体を束縛するため、秘密値はcache metadataへ書かない。diagnostic用には変数名、値digest、
変更された変数名だけを返す。cache key、artifact、activityのいずれにも平文secretを複製しない。

### 3. relevant inputの完全性

project profileのcheck descriptorは、検査ごとにinput providerと完全性を宣言する。cache eligibleなのは、現在の
manifest、lockfile、source、resource、generated input、compiler/plugin設定、directory membershipまで含むdependency
closureを`complete`として発行できる場合だけである。providerの証拠にはprovider version、取得元、workspace cursor、
対象target、leaf件数、Merkle rootを含める。

`change_impact`はchanged path/symbolから検査候補を絞るseamであり、cache freshnessの完全性正本ではない。
impact resultの`candidate_only`、heuristic、stale、unavailableな集合をrelevant input全体として使わない。impactが選んだ
focused checkでも、そのcheck固有の完全dependency closureを別途構成できた時だけcache可能にする。closure不明なら
検査はuncachedで実行し、暗黙にworkspace全体hash又は前回input setへ切り替えない。

project profileがstale、cursor失効、manifest変更、toolchain probe失敗の時は`CACHE_BINDING_INCOMPLETE`と理由を返す。
caller supplied pathやhashをOS照合なしに信用しない。将来providerを追加してcache対象を広げることはできるが、
完全性を証明できない検査をhit率のためにeligibleへ昇格しない。

### 4. 外部効果とcache eligibility

network、wall clock、未束縛randomness、外部service、root外の可変file、ユーザー対話へ結果が依存し得る検査はcacheしない。
任意の`run_check` commandはopen-worldなので既定でineligibleである。eligibleにできるのは、built-in又はversioned project
profile providerが次を証拠化した検査だけとする。

- networkが無効又は全応答がimmutable digestへ束縛されている。
- clockが結果へ影響しない、又は固定clock値がkeyへ束縛されている。
- randomnessが使われない、又はseedとgenerator versionがkeyへ束縛されている。
- root外入力、service response、plugin、generated fileを含む全可変入力がkeyへ束縛されている。

providerがこのeffect receiptを発行できない場合は`CACHE_EFFECTS_UNBOUND`でineligibleにする。実行後に「たぶん
deterministicだった」と推測して保存しない。環境変数名やargument文字列のdenylistだけを完全性証明として使わない。

### 5. 保存・hit・terminal state

再利用できるのは、processと全stdout/stderr artifactが確定した後の次のterminal resultだけである。

- exit reasonがnormal exitかつexit 0の`passed`。
- exit reasonがnormal exitかつnonzero exitの`failed`。

失敗結果も同じ完全bindingなら有用な一次証拠なので再利用する。timeout、cancel、signal termination、launch failure、
server interruption、artifact確定失敗、infrastructure errorは保存しない。特にtimeoutを通常のfailedへ丸めず、別timeoutで
得た結果を再利用しない。

entryはkey、binding summary、terminal result、stdout/stderr artifact metadata、各artifact SHA-256、作成時刻、
retention期限、payload SHA-256を一つのimmutable recordとしてatomic commitする。entryのretentionは全参照artifactの
retentionを超えない。hit時にはentry payload、key、artifact存在、size、SHA-256を再検証してから返す。hitはTTLを延長せず、
元entryを上書きしない。期限切れ又はartifact失効は`prefer`では理由付きmissとして新規実行でき、`only`では
`CACHE_EXPIRED`で停止する。

decode失敗、payload hash不一致、key/path不一致、artifact hash不一致は`CACHE_CORRUPT`とし、自動削除、自動再実行、
空entry扱いをしない。別keyのentry、類似arguments、古いprofile、部分一致inputから結果を返さない。quota evictionは
完全entry単位だけで行い、evict後のlookupは`CACHE_EVICTED`を理由に持つmissとする。TTLとquotaの具体値、atomic replace、
corruption recoveryはACE-031の先行安全網で固定する。

### 6. invalidationと観測可能性

lookup resultには一致したbinding categoryと、miss/ineligibleなら最初に不一致となったcategoryを返す。
categoryは少なくとも`executable`、`arguments`、`working_directory`、`environment`、`project_profile`、`toolchain`、
`relevant_inputs`、`execution_policy`、`expired`、`evicted`を持つ。過去entryとの比較が可能な時は旧新digestだけを返し、
environment値やfile内容をdiagnosticへ展開しない。

cache metadataの破損と通常のfreshness missを区別する。通常missは現在keyに一致するentryがない状態、corruptは存在する
entryを信用できない状態である。corruptをmissへ丸めると壊れた一次証拠を握りつぶすため禁止する。

## Verification contract

ACE-031は少なくとも次のfocused fixtureを先行実装する。

- 同一binary、ordered arguments、cwd identity、effective environment、profile/toolchain、完全input closureでは、
  `passed`とnormal-exit `failed`がそれぞれhitし、process起動回数が増えない。
- executable bytes/symlink target、argument順又は空要素、cwd inode、継承environment、manifest、lockfile、toolchain raw
  probe、input content、directory membershipの各単独変更でmissになり、false-freshが0件である。
- size/mtimeを元へ戻したinput変更、rename、追加、削除、同path inode置換でもrelevant input rootが変わる。
- incomplete/stale project profile、candidate-only impact、unbound network/time/randomnessはineligibleであり、`only`は
  typed error、`prefer`は理由付きuncached executionになる。
- timeout、cancel、signal、launch failure、artifact確定失敗を保存せず、passed/failedだけを再利用する。
- entry payload、key、stdout、stderrをそれぞれ1 byte破損すると`CACHE_CORRUPT`になり、processを自動再実行しない。
- TTL境界、artifact先行失効、quota eviction、atomic commit失敗を固定し、hitによってexpiryが延びない。
- cache省略時のv1互換実行、`mode=off`、`refresh`、`only` miss、secret非露出を固定する。

focused testは実process counterとartifact SHAから「実行されたか」「同じ確定証拠が再利用されたか」を独立判定する。
responseの`cache.state`だけをoracleにしない。

## Consequences

ACE-034aは`CheckFreshnessCache`を専用domain serviceとして実装し、ACE-034が`DevelopmentRuntimeService`へ統合する。
MCP handlerにはschema変換だけを置く。project profileはcheck descriptor、toolchain、完全input providerを供給し、
`change_impact`は候補選択だけを供給する。このseamを越えてimpact heuristicをfreshness authorityへ昇格しない。

この契約はcache不能な検査の実行能力を削除しない。証明できない検査は明示的にuncachedで実行する。hit率より
correctnessを優先し、false-fresh 0件をPhase 3受入の必須条件とする。
