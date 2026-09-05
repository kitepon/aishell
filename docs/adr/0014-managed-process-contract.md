# ADR 0014: 管理processと非同期run契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-21
- Lattice task: `ACE-040`
- Control: `aishell-capability-expansion-20260721`

## Context

現行`run_check`はMCP request内でprocess終了まで待ち、終了後にstdout/stderrをartifactへコピーする。
この間MCP serverの標準入力loopも次requestを処理できないため、同じconnectionからstatus確認、incremental evidence取得、
cancel、`workspace_wait`などを並行実行できない。MCP adapterが終了すればprocess identityと実行中spoolの所有者も失われ、
PID再利用、descendant残留、終了とcancel/timeoutのrace、artifact確定前の障害を機械的に判定できない。

Phase 4ではAI hostのthreadや汎用PTYを再実装せず、AIShellが直接起動したprocessのlifecycleと完全証拠だけを所有する。
そのため、公開run handle、永続registry、MCP adapterから独立したsupervisor、live spool、終端後のimmutable artifactを
一つの管理runとして束縛する。

## Decision

### 1. 公開tool境界

本ADRが所有する`run_check`入力は`dispatch.mode: start | sync`と、そのmodeに必要なlifecycle fieldだけである。
`aishell.run-check.v2`共通schema、check/pipeline選択、cache、diagnostic envelopeとの統合はACE-030／ACE-033との
seam裁定まで確定しない。本ADRの`dispatch`をtop-level `action`へ読み替えたり、v2全体schemaの決定として扱ったりしない。

非同期`dispatch.mode: start`ではcallerが1〜128 bytesの`client_run_key`を必須で渡す。
同じkeyと同じcanonical request digestの再送は既存run handleを返し、異なるrequestでの再利用は
`RUN_KEY_CONFLICT`とする。response喪失やrequest cancellation後も同じkeyで回収でき、重複processを起動しない。
`start`はlaunch admissionと永続化が完了した時点で返り、
dispatch resultとして少なくとも次を返す。

- opaqueな`run_handle`、安定した`run_id`、`state_revision`
- `state: starting | running | cancelling | timing_out | finalizing | recovery_required | passed | failed | timed_out | cancelled | interrupted`
- 解決済みexecutable、arguments、working directory、environment digest、開始時刻、timeout deadline
- stdout/stderrのlive cursor、`started_at`、要求された`retention_seconds`

`run_handle`はrun UUID、registry generation、所有state directory identityへ束縛した認証付きtokenとし、認証secretも
同じAIShell state directoryへ原子的に永続化する。MCP adapter再起動後も同じhandleを使えなければならない。
改ざんは`INVALID_RUN_HANDLE`、別state directoryのhandleは`RUN_STORE_MISMATCH`、retention後は`RUN_EXPIRED`とし、
PID、request ID、artifact handleをrun handleとして代用しない。

`dispatch.mode: sync`は同じmanaged runを開始して終端まで待つ互換adapterである。現行v1 input、timeout、
`passed | failed | timed_out`、summary、primary diagnostic、exit code、duration、完全stdout/stderr artifactを維持する。
`AISHELL_SCHEMA_COMPAT=v1`ではv1 shapeへ投影し、v2では対応する`run_handle`も返す。同期互換経路のために別process
実装を残さず、既定development profileのtool数やfull profileの既存primitiveを削減しない。

ADR 0018の`RunCheckInvocationPlan`導入後、managed runは「必ず一つのprocessをspawnするrun」ではなく、同じimmutable
check invocation planへ束縛される0..N child processを所有する。`dispatch.mode: start`はprocess spawnの保証ではなく
managed invocation admissionである。`cache: prefer | only`で全stepがcache hitした場合も同期resultへ暗黙変換せず、
process 0件の即時terminal runとして同じ`run_handle`を返し、参照したsource runとartifact SHAを証拠化する。
架空PID、架空duration、架空launch eventは作らない。

作成後の観測と変更は`run_observe`だけが所有し、次のactionを持つ。

| action | 意味 |
|---|---|
| `status` | 現在state、revision、終了情報、stream offset、artifact確定状態を即時に返す |
| `read` | 指定cursor以後のstdout/stderrとdiagnostic eventを共有byte budget内で返す |
| `wait` | state revisionまたはevidence cursorが進むまで、1〜300,000msの上限付きで待つ |
| `cancel` | 対象runの停止transactionを開始し、既に開始済みなら同じcancel結果へ合流する |

すべての`run_observe` actionは認証済み`run_handle`を必須入力とする。`run_id`はterminal artifact indexと
ACE-042のhistory/query参照だけに使う非秘密識別子であり、status/read/wait/cancelの認可には使えない。
`run_handle`を`run_id`、PID、artifact handleから導出・検索するAPIも提供しない。

`wait`のtimeoutはrun失敗ではなく`wait_outcome: timed_out`であり、run stateを変えない。MCP request cancellationは
その`wait`／`read` requestだけを終了し、明示`cancel`なしにrunを停止しない。`cancel`はdestructive action、他3 actionは
観測だが、tool annotationはactionごとに変えられないため`run_observe`全体をdestructiveのまま維持する。

### 2. run state machineとaction可否

公開stateごとの`run_observe`可否を次で固定する。`read`はその時点までに永続化済みのspoolだけを読み、`wait`の
「即時」は新しいevidenceを待たず現在snapshotを返すことを意味する。

| state | `status` | `read` | `wait` | `cancel` |
|---|---|---|---|---|
| `starting` | 可 | 可（0 bytes可） | 可 | 可（launch中止を記録） |
| `running` | 可 | 可 | 可 | 可（`cancelling`へ） |
| `cancelling` | 可 | 可 | 可 | 可（同じcancelへ冪等合流） |
| `timing_out` | 可 | 可 | 可 | 可（timeout causeを変えず冪等snapshot） |
| `finalizing` | 可 | 可 | 可 | 不可（`RUN_NOT_CANCELLABLE`） |
| `recovery_required` | 可 | 可（永続済み範囲だけ） | 可 | 条件付き可（identity照合成功時だけ停止を再試行） |
| `passed` | 可 | 可 | 可（即時） | 可（terminal snapshotを無変更で返す） |
| `failed` | 可 | 可 | 可（即時） | 可（terminal snapshotを無変更で返す） |
| `timed_out` | 可 | 可 | 可（即時） | 可（terminal snapshotを無変更で返す） |
| `cancelled` | 可 | 可 | 可（即時） | 可（terminal snapshotを無変更で返す） |
| `interrupted` | 可 | 可 | 可（即時） | 可（terminal snapshotを無変更で返す） |

`recovery_required`でidentityを証明できないcancelはsignalを送らず`RUN_RECOVERY_REQUIRED`を返す。禁止actionを
別actionへ暗黙変換しない。run stateは次の遷移だけを許す。

```text
starting -> running | cancelling | timing_out | finalizing | recovery_required
running -> cancelling | timing_out | finalizing | recovery_required
cancelling -> finalizing | recovery_required
timing_out -> finalizing | recovery_required
finalizing -> passed | failed | timed_out | cancelled | interrupted | recovery_required
recovery_required -> running | cancelling | timing_out | finalizing
```

`finalizing`からのterminal stateは永続化済みterminal causeと一致するものだけを許す。`interrupted`は
recovery causeを持つrunだけ、`cancelled`はcancel受理済みrunだけ、`timed_out`はdeadline受理済みrunだけへ許す。
`recovery_required`から非terminalへ戻る時は、同一boot/session、supervisor nonce、PID start identityを再照合し、
直前の永続causeへ対応するstateへだけ復帰する。terminal stateからの遷移はない。

launch admissionのlinearization pointは、run directory、request manifest、初期registry record、stdout/stderr spoolを
同一filesystem上へ書いてfsyncし、supervisorが所有権をacknowledgeした後である。それ以前の失敗はhandleを返さず、
孤児directoryをrecovery対象として記録する。以後は単調増加する`state_revision`とappend-only event journalへ各遷移を
先に永続化してから公開する。未知状態、revision逆行、journal/manifest digest不一致は`RUN_STORE_CORRUPT`で停止する。

admission成立後に`posix_spawn`、executable identity再照合、working directory open、file descriptor接続のいずれかが失敗した
場合は、既に発行したhandleとrunを消さない。terminal causeを`launch_failed`としてjournalへ先に永続化し、空でも
stdout/stderr artifactを通常のfinalization transactionで確定して、`state: failed`、`exit_code: null`、
`termination_cause: launch_failed`へ遷移させる。`start`の初回responseまたは後続`status`はterminal snapshotと併せて
typed error `RUN_LAUNCH_FAILED`と、秘密を含まない失敗stage／OS error categoryを返す。spawn失敗をadmission前失敗へ
巻き戻したり、exit code 127等の架空値へ変換したり、同じ`client_run_key`で別processを再launchしたりしない。

自然終了、timeout、cancelが競合した時は、registry actorが受理して永続化した最初のcauseだけがterminal causeになる。
終了を既にreap済みなら後着cancelはterminal snapshotをそのまま返す。cancelを先に受理した場合は、その後exit 0でも
`cancelled`とし、timeoutを先に受理した場合は`timed_out`とする。重複cancelはidempotentで、新しいsignal列やrunを作らない。

`passed`はexit code 0、`failed`はexit code nonzero、通常のsignal終了、またはadmission後の`launch_failed`である。
`launch_failed`、`timed_out`、`cancelled`、`interrupted`はexit codeを推測せずnullを許す。すべてのterminal resultは`termination_cause`、signal、cancel受理時刻、
timeout deadline、開始/終了時刻、duration、artifact descriptorを同じrevisionに持つ。

### 3. supervisor、process group、再起動

各runはMCP stdio adapterとは別processの`AIShellRunSupervisor`が所有する。supervisorはshell文字列を評価せず、
検証済みexecutable URL、ordered arguments、working directory、effective environmentを分離したまま起動する。
launch materialを含むrun directoryはownerだけが読めるpermissionにし、公開resultやjournalへenvironment値を出さずdigestだけを出す。
対象commandを`posix_spawn`の`POSIX_SPAWN_SETPGROUP`で新しいprocess groupへ原子的に置き、run manifest/indexへ次を保存する。

- `project_binding`と、effective allowed rootのcanonical path・volume UUID・device/inode identity
- working directoryのcanonical path・device/inode identity
- 解決済みexecutable path、device/inode、content SHA-256からなるexecutable content identity
- boot session identity
- supervisor PIDとstart identity
- command PID、start identity、process group ID
- request digest、run directory identity、supervisor protocol version
- check ID／pipeline IDと各contract revision（未指定はnullではなく`availability: not_requested`）
- project profile/toolchain/relevant input bindingのdigestと、それぞれのclosed unionである
  `availability: bound | not_requested | ambiguous | unavailable`

`project_binding`は`availability: bound | not_requested | ambiguous | unavailable`のclosed unionとする。`bound`だけが
`project_id`を必須で持ち、他3 variantは`project_id`を持たずtyped reasonを必須にする。複数project候補が同順位なら
`ambiguous`、project解決を要求していない入力は`not_requested`、catalogやidentityを取得不能なら`unavailable`であり、
どれも空文字やnull IDへ潰さない。一方、effective allowed-root identityはproject解決の成否にかかわらず常にmanifestへ
保存する。allowed-root自体を一意に解決・identity照合できないrequestはlaunch admission前にtyped errorで拒否し、
`project_binding: unavailable`をallowed-root不在の代用にしない。

各bindingが`ambiguous`または`unavailable`ならtyped reasonを保存し、未取得値を空digestや「fresh」として扱わない。ACE-030のcache hit、
ACE-033のfocused pipeline実行、ACE-042のhistory compareはこのimmutable bindingを参照し、run終了後の現在値で
書き換えない。公開resultには秘密を含まないidentity/digestとavailabilityだけを投影する。

cancel/timeoutは保存PIDだけへsignalしない。boot session、PID start identity、group membershipを再照合し、同じrunの
process groupへ`SIGTERM`、grace period後に`SIGKILL`を送る。通常の同一group descendantも対象にし、group消滅、root reap、
stdout/stderr両方のEOFを確認するまでterminalへ進めない。PID再利用やidentity不一致は`recovery_required`とし、
別processへsignalしない。意図的に`setsid`／double-forkして管理groupから離脱するworkerを封じるsecurity boundaryとは
主張しないが、検出した逸脱processは`UNMANAGED_DESCENDANT`としてrunを成功扱いしない。

MCP adapter再起動時はrun registryを列挙し、同じboot sessionのsupervisor socketへrun nonce付きで再接続する。
再接続できれば同じhandle、revision、spool cursorから観測を続ける。host reboot、supervisor消失、protocol不一致、
identity不一致では、実行中recordを`passed`／`failed`へ推測変換しない。照合済みprocess groupを安全に停止・reapできるまで
`recovery_required`とし、回収後だけ`interrupted`へ確定する。安全な停止を証明できなければ
`RUN_RECOVERY_REQUIRED`を返し、artifact確定やregistry GCを行わない。

AIShell runtimeの全体pauseは新規startを拒否するが、既存runのstatus/read/wait/cancelとrecoveryは利用可能にする。
adapter disconnect、client request cancellation、runtime pauseをrun cancelへ暗黙変換しない。

### 4. live spool、incremental evidence、finalization

supervisorはlaunch前にrun directory内へstdout/stderr spoolを作り、対象processのfile descriptorを直接接続する。
spoolはadvertised retention前に上書き・truncate・rotateせず、quota admissionはprocess起動前に行う。実行中のquota枯渇は
一部出力を黙って捨てずrunを停止して`EVIDENCE_QUOTA_EXCEEDED`をterminal evidenceへ記録する。

incremental cursorはrun identity、event sequence、stdout offset、stderr offset、diagnostic offsetへ束縛したopaque tokenである。
`read`／`wait`はstdout、stderr、structured diagnostic eventをそれぞれstream sequence付きで返し、stream間の全順序を
捏造しない。共有`byte_budget`は1〜1,048,576 bytes、既定65,536とし、一つのUTF-8 scalarまたはbinary chunkを途中で
切らない。返し切れない時は`has_more`、stream別`omitted_bytes`、次cursorを返す。cursor改ざんは
`INVALID_RUN_CURSOR`、run不一致は`RUN_CURSOR_MISMATCH`、既知offsetより先は`RUN_CURSOR_AHEAD`とする。

live spoolは可変な一次証拠であり、通常の`artifact_read` handleとして公開しない。terminal causeが固定され、process group消滅、
root reap、両stream EOF、file fsyncを確認した後だけ`finalizing`へ進み、spool全bytesのsize、line count、SHA-256を計算して
immutable stdout/stderr artifactへ発行する。片方のartifact発行、metadata書込み、terminal registry更新を一つの
finalization transactionとして扱い、一部だけ公開しない。失敗時は`finalizing`に留め、再試行可能にする。

`expires_at`はprocess開始時でなくterminal finalization時から`retention_seconds`を加算する。run manifest、journal、
diagnostic artifact、stdout/stderr artifactは同じexpiryまで保持し、advertised retention中は個別GCしない。expiry後のGCは
run単位でrename-to-trash相当の原子的cutoverを行ってから削除する。active、`recovery_required`、`finalizing`は期限だけで
GCしない。

### 5. MCP request concurrency

MCP stdio readerは一requestずつ`await`する構造を廃止し、decodeとadmission後にrequest IDごとのSwift `Task`へdispatchする。
response writerだけをactorで直列化し、一つのJSON-RPC responseを一行として不可分に書く。requestの完了順は受付順でなくてよいが、
各IDへresponseは一回だけ返す。重複中のrequest IDはprotocol errorにし、notificationはresponseを作らない。

JSON-RPC cancellation notificationは対応request taskへだけ伝播する。`run_check`の`dispatch.mode: start` admission完了後、response送信前に
requestがcancelされてもrunは消さず、journalへrequest cancellationを記録し、同じ`client_run_key`の再送で同じhandleを返す。
同時`run_observe`はrun actorがrevisionとcursorを直列化し、MCP readerやresponse writerを長時間占有しない。
server shutdownは新規admissionを止め、未完response taskをcancelするが、supervisor所有runは継続させる。

### 6. `artifact_read`／ACE-042とのseam

run registryはterminal finalization時に、安定した`run_id`からstdout、stderr、diagnostic artifact handle、request digest、
terminal summary、toolchain/input bindingへ引けるimmutable index recordを発行する。ACE-042の横断pattern検索、diagnostic group、
history compareはこのindexと確定artifactだけを読む。process statusを変更したりlive spoolを直接開いたりしない。

active／`recovery_required`／`finalizing` runをartifact queryへ指定した場合は`RUN_NOT_FINALIZED`とし、暗黙にwaitせず、
途中spoolを過去runとして比較しない。incremental tailが必要なcallerは`run_observe read/wait`を使う。artifact index更新失敗は
runを`finalizing`に留め、terminal stateだけ先に公開しない。このseamによりACE-040とACE-042は同じspoolやlifecycleを
二重所有しない。

## Verification contract

ACE-041はproductionと同じsupervisor protocolを使うfocused fixtureで、少なくとも次を固定する。

- long-running commandの`start`が終了前に返り、同一connectionでstatus/read/waitを並行処理できる。
- stdout/stderrを複数回追記したrunでcursor連結が完全bytesと一致し、重複・欠落・silent truncationがない。
- cancel直前/直後の自然終了、timeoutとcancelの同時到着をbarrierで再現し、terminal causeが一つだけになる。
- childとgrandchildを持つprocessでTERM→KILL、process group消滅、PID start identity照合、PID再利用拒否を確認する。
- MCP adapterだけを再起動して同じhandle/cursorでrunning runへ再接続し、supervisor消失とhost boot identity変更は
  `recovery_required`から`interrupted`へfail closedで回収する。
- stdoutだけEOF、stderr write継続、artifact二個目の発行失敗、registry書込み失敗、quota枯渇を注入し、
  `finalizing`前のartifact公開と部分terminal resultがない。
- admission成立後のspawn、executable identity再照合、working directory open、FD接続失敗を注入し、handleを維持した
  `failed`、`exit_code: null`、`termination_cause: launch_failed`、`RUN_LAUNCH_FAILED`と空stream artifactの確定を固定する。
- terminal finalization時刻を基準にexpiryを独立計算し、retention中はartifact/run indexが残り、active runがGCされない。
- request ID重複、request cancellation、response順逆転、同時status/read/waitでresponse混線がない。
- ACE-042 seam fixtureはactive runを`RUN_NOT_FINALIZED`にし、terminal runのindexからstdout/stderr/diagnostic SHAを一致させる。
- 既存`run_check` v1の成功、失敗、timeout、primary diagnostic、完全artifactと、default/full tool catalogを非回帰にする。
- full profileのlegacy `process_run`について、executable/arguments/cwd/environment、同期終了、stdout/stderr、exit code、
  `terminationReason`、`durationMilliseconds`、`stdoutTruncated`、`stderrTruncated`、timeout時のdescendant停止という
  現行response/挙動をcharacterization fixtureでbyte-for-byte固定する。managed run実装へ内部統合しても、
  `process_run`を削除したり`run_check` v2 resultへ置換したりしない。

凍結済み`benchmarks/representative-suite.v1.json`、`representative-task-goals.v1.json`、
`representative-execution-contracts.v1.json`のprompt、arm、task ID、fixture、oracleは変更しない。Phase 4の
`async-process-first-useful-result`と`async-process-cancel`もv1比較条件のまま実測する。統合後の`run_check` v2
dispatch shapeを測定入力へ採用するcutoverは、全seam裁定とwire fixtureが揃った後に別のv2 benchmark contractとして行い、
v1を遡及更新しない。benchmark v2の統合実装taskは、そのschema、materializer、projection、fixture、oracle、expected digestを
byte-for-byte固定する専用freeze taskの完了に依存させ、freeze前に計測実装やbaseline収集へ進めない。freeze task自身も
ACE-030／ACE-033との共通`run_check` seam裁定を前提とする。

実装中はrun registry state machine、supervisor protocol、MCP concurrent dispatcherをそれぞれfocused testで確認する。
Phase 4 gateで関連test、`swift test`、MCP initialize/tools/list、start→read→wait→terminal、cancel、adapter再起動fixtureを
一回通す。fixture未実装のraceや悪意あるdaemon escapeを検証済みと主張しない。

## Consequences

ACE-044は`AIShellCore`へrun registry、supervisor client、spool/finalization serviceを置き、`AIShellMCP`にはaction変換、
concurrent request dispatch、response serializationだけを置く。process lifecycleをMCP handlerへ埋め込まない。
既存`NativeProcessService`の同期captureは互換adapterからmanaged runへ置換し、並行する第二の所有経路として残さない。

per-run supervisorと永続spoolにはprocess・disk costがあるが、MCP adapter障害からrunを分離し、再接続、PID identity、完全証拠を
同じ契約で満たすために受け入れる。単純な短命checkも同じ経路を使い、性能差はPhase 4 benchmarkで測る。

本契約はAIShellが直接起動したprocessと通常の同一process group descendantだけを対象とする。汎用shell、remote job scheduler、
AI hostのthread/sub-agent、悪意を持って管理groupを脱出するprocessの封じ込めは非目標である。
