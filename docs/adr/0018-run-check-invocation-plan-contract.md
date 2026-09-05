# ADR 0018: RunCheckInvocationPlan共通契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-22
- Lattice task: `ACE-029`
- Control: `aishell-capability-expansion-20260721`

## Context

freshness cache、focused check、managed processはすべて`run_check`を消費するが、invocation選択、dispatch、cache policyを
各機能が別々に解釈すると、cache miss時だけdirect実行へ退行する、focused集合がcache状態で変わる、syncとstartで
別planを実行する、といったsilent fallbackが生じる。3軸を一つのimmutable planへ束縛し、consumer間の所有境界を固定する。

## Decision

### 1. Closed typeとv1正規化

`RunCheckInvocationPlan`はschema `aishell.run-check-invocation-plan.v1`を持ち、次をcanonical bytesとdigestへ束縛する。

- `invocation`: `direct | profile_check | focused_set`
- `dispatch`: `sync | start`
- `cache`: `off | prefer | only | refresh`
- execution policy、selection digest、request digest

`direct`はordered executable、arguments、working directory、effective environmentを持つ。
`profile_check`はproject ID、profile digest、check IDを持つ。`focused_set`はset IDと、空でなく重複しないordered check IDを持つ。
`start`だけが1〜128 bytesの`client_run_key`を必須にする。unionの未知variant、余剰field、複数variant混在はprocess admission前に拒否する。

既存v1 flat requestは`direct + sync + off`へだけ正規化する。v1 fieldとv2 objectの混在、cache可能profileへの推測変換、
startへの暗黙昇格は禁止する。これにより現行direct同期実行を削減せず、v2の新しい意味をv1へ捏造しない。

### 2. 合法性matrix

| invocation | `off` | `prefer` | `only` | `refresh` | dispatch |
|---|---|---|---|---|---|
| `direct` | 合法 | 拒否 | 拒否 | 拒否 | `sync` / `start` |
| `profile_check` | 合法 | 合法 | 合法 | 合法 | `sync` / `start` |
| `focused_set` | 合法 | 合法 | 合法 | 合法 | `sync` / `start` |

dispatchを含む24直積のうち18組合せを合法、`direct + cache != off`の6組合せを
`RUN_CHECK_CACHE_NOT_ALLOWED`で拒否する。arbitrary direct commandをcache eligibleへ見せないためであり、direct実行自体は維持する。

### 3. Cache policy

- `off`: lookup/storeを行わず、選択済みplanを必ず実行する。
- `prefer`: complete hitは再利用する。missまたはbinding不足は同じplanをuncached実行し、`miss_executed`または
  `ineligible`を明示する。invocationをdirectへ変えない。
- `only`: 全stepのlookupをprocess admission前に行う。一件でもmiss、incomplete、expiredなら全体をtyped errorにし、
  process起動0件とする。focused setの部分hitを部分成功へ変えない。
- `refresh`: lookupせず全stepを実行し、eligibleなterminal resultだけを新しいimmutable entryへ保存する。
  既存entryのin-place置換やpreferへのfallbackは禁止する。

corruptionは`CACHE_CORRUPT`で停止し、削除、miss化、uncached実行をしない。cache policyはrequested/planned check集合、
step DAG、selection digestを変更しない。cache hitしたfailed resultはfailedのまま再利用し、新規成功や新規実行に見せない。
selection自体がstaleなら全modeで拒否する。selectionがcurrentでcache bindingだけ不足する場合だけ、`prefer`と`refresh`は
同じplanをuncached実行できる。

### 4. Dispatchとmanaged invocation

`sync`と`start`は同じplan、selection digest、cache判断、step集合を使い、違いは待機方法だけである。
`sync`もmanaged invocationをadmitしてterminalまで待つ。`start`は同じclient keyとplan digestなら同じhandleを返し、
同じkeyと異なるdigestは`RUN_KEY_CONFLICT`とする。

`start + prefer | only`で全stepがcache hitしてもsyncへ変換しない。0 processの即時terminal managed invocationを作り、
run handle、cache evidence、source run、artifact SHAを返す。managed invocationは0..N child processを所有できる。
架空PID、架空duration、架空launch failureは作らない。`only` miss、structural one-of違反、unknown/duplicate check、stale set、
invalid provenanceはadmission前に拒否し、process起動0件を証拠化する。

### 5. Selectionとconsumer ownership

- `direct`: callerがcommand materialを所有し、AIShellが許可root、executable、cwd、environmentを検証する。
- `profile_check`: `ProjectProfileService`がproject ID、profile digest、check IDからdescriptor、provenance、freshnessを解決する。
- `focused_set`: `ChangeImpactService`とFocused Check providerが候補/setを発行し、callerが選んだ集合をstep DAGへ変換する。
- ACE-029: 3軸、one-of、合法性、v1正規化、plan/request/selection digest、処理順を所有する。
- ACE-030: cache binding/key、eligibility、lookup/store、cache state/errorだけを所有し、invocation/dispatchを選ばない。
- ACE-033: focused候補/set、selection再照合、step DAGだけを所有し、cache/dispatchを暗黙選択しない。
- ACE-040/041: handle、idempotent admission、state/cursor/cancel、supervisorを所有し、check/cacheを選ばない。
- ACE-034: 共通planをruntime、MCP、cache、focused、managed invocationへ統合する。

### 6. Error contract

少なくとも次をclosed errorとして機械判定可能にする。

- `RUN_CHECK_INVOCATION_INVALID`: union違反、unknown/duplicate ID、余剰field
- `RUN_CHECK_CACHE_NOT_ALLOWED`: directとoff以外の組合せ
- `RUN_CHECK_SELECTION_STALE`: profile/setのidentityまたはselection digest不一致
- `RUN_CHECK_CACHE_MISS`: `only`のmiss/incomplete/expired。step別lookup evidenceを持つ
- `CACHE_CORRUPT`: entry/manifest/digest破損
- `RUN_KEY_CONFLICT`: client keyの異digest再利用

禁止組合せを別modeへ変換せず、error時のprocess countを明示する。

### 7. ACE-034公開runtime cutover

公開`run_check`はcallerからprofile catalog、relevant-input digest、再観測closureを受け取らない。
`DevelopmentRuntimeService`が共有`ProjectProfileService`とDirect OS observationからexact profile/check、
environmentの宣言済みkey、relevant-input receiptを解決し、実行後も同じauthorityで再観測する。
環境変数の未設定は値の省略としてcanonical bindingへ含め、hostに存在しない`DEVELOPER_DIR`や`SDKROOT`を
一律staleにしない。

公開schemaも合法性matrixと同じく`direct`のcacheを`off`へ閉じる。v2のidentifier、argument、ordered IDは
schemaの4,096上限をruntime decodeでも検証し、SHA-256はASCII lowercase hexだけを受理する。
profile、cursor、manifest、focused setのdriftは`RUN_CHECK_SELECTION_STALE`、観測中の内容変更は
`CONTENT_CHANGED`へ変換し、いずれもprocess 0で返す。未知の内部障害をstaleへ丸めない。
複数owner rootが登録されている場合、project IDまたはprofile digestを持つcache索引で候補rootを一意に絞ってから
そのroot固有cursorを再観測し、一つのrootのcursorを別rootへ適用しない。候補rootが複数なら曖昧性としてfail closedする。

`change_impact`のanalyze/recommend/continuationも同じ`DevelopmentRuntimeService`所有serviceへ結線する。
continuation tokenは複数registryのprefix推測で選ばず、exact membershipが一意な場合だけ一度消費する。

## Verification contract

- 24直積をtable-drivenで固定し、18合法/6拒否を確認する。
- v1 flat requestは`direct/sync/off`だけへ正規化し、v1/v2混在をprocess 0件で拒否する。
- profile/focusedの4 cache modeをsync/start双方で確認し、process counter、plan digest、artifact SHAを照合する。
- `focused_set + only`の部分hit/missでprocess 0件、部分成功0件を確認する。
- cache-only startがterminal handleを返し、同じclient keyで同じhandle、process 0件になることを確認する。
- sync/startのrequested/planned IDs、step DAG、cache evidence、terminal plan digestを一致させる。
- stale selection、corruption、unknown/duplicate ID、run key conflictをexact typed errorで固定する。
- MCP input schemaのclosed union、`additionalProperties: false`、成功/失敗structured fixtureを確認する。
- schema/runtime双方でdirect + non-off cache、非ASCII digest、上限超過inputを拒否する。
- public profile/focused実行がcaller supplied catalogなしで成功し、profile/cursor driftがprocess 0のtyped staleになることを確認する。
- 既存direct runの成功、失敗、timeout、primary diagnostic、完全stdout/stderr artifactを非回帰にする。

## Consequences

実装は`AIShellCore`へ共通plan compilerを置き、MCP handler、cache、focused provider、managed registryへ解釈を分散しない。
cache-only managed invocationとfocused 0..N childに対応するためregistry/protocolは拡張するが、既存direct sync経路、full profileの
`process_run`、既存20 primitiveは削除しない。ADR 0014のmanaged process契約は本ADRのmanaged invocation seamで補完する。
