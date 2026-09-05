# ADR 0016: workspace wait契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-21
- Lattice task: `ACE-043`
- Control: `aishell-capability-expansion-20260721`

## Context

現行`workspace_snapshot`はrequest時点までの状態を返せるが、次のOS変更を待つにはAI hostがpollを反復する必要がある。
一方、待機を既存snapshot handlerへ埋め込むと、現在の逐次MCP受付を占有し、cancel通知、別tool、process観測まで
停止させる。また、現行journalの「snapshotが処理済みeventを破棄する」実装をそのまま使うと、複数waiterが
同じcursorから待った時に先着consumerが履歴を奪い、後続consumerが変更を失う。

Phase 4では、filesystem変更を待つ操作を独立したread-only toolへ分離する。FSEventsは引き続きdirty pathの通知だけに使い、
file identity、metadata、content SHAとの照合結果をworkspace runtimeが所有する。待機requestは履歴の所有者にも
acknowledgementにもせず、同じimmutable deltaを各cursorから再生できるfan-out consumerとする。

## Decision

### 1. 公開境界

default development profileへ独立tool `workspace_wait`を追加する。これは`workspace_snapshot`のlong-poll optionではなく、
filesystemを変更しないread-only toolである。entry一覧、埋込context、Git状態、full scanは返さない。

requestは次を持つ。

- `cursor`: 必須。ADR 0004の`ws2` cursorだけを受け付ける。
- `path`: 省略可能。指定時は既存`workspace_snapshot`と同じ許可root解決を行い、cursorのroot identityと一致させる。
  省略時はcursorに対応する現在open中のrootを使い、一意に解決できなければ`CURSOR_EXPIRED`とする。
- `timeout_ms`: 0〜300,000 ms。既定30,000 ms。0はblockしないpollである。
- `change_limit`: 1〜1,000件。既定200件。件数超過を黙って捨てない。

result schemaは`aishell.workspace-wait.v1`とし、次を必須にする。

- `status`: `changed | timeout`のclosed set。
- `root`、`fromCursor`、`cursor`、`freshness`。
- sequence順の`changes`。各要素は既存`WorkspaceChange`のkind、path、旧path、identity、metadata、content SHAを再利用する。
- `observedEvents`、`returnedChanges`、`omittedChanges`、`hasMore`、`waitedMs`。

保持済みdeltaがcursor後にあれば待たずに返す。`change_limit`を超える時は、返した最後のrecordまでのcursorだけを返し、
`hasMore=true`と正確な`omittedChanges`を示す。callerはそのcursorで`timeout_ms=0`を再呼出しできる。
上限内なら、返すcursorは結果生成時点までに照合済みのno-op eventも含む最新sequenceへ進めてよい。
FSEvents通知を照合した結果、semantic changeが一件もないまま期限へ達した時は`status=timeout`、空`changes`と、
照合済み位置まで進んだcursorを返す。除外pathはADR 0004どおりjournal sequenceへ入れない。

timeoutは正常な待機結果でありerrorにしない。deadlineはmonotonic clockで測り、wall clock変更で延長・短縮しない。
`waitedMs`は観測値であってfreshness根拠に使わない。

### 2. WorkspaceDeltaJournalの所有境界

`WorkspaceDeltaJournal`をworkspace entry checkpoint、FSEvents observer、waiter registryから独立した
`AIShellCore`の所有面とする。保存先は
`RuntimeStore.baseDirectory/workspaces/<root_digest>/generations/<generation>/delta-journal/`で、root identity、
exclusion digest、generation、retention floor、head observation sequence、head semantic delta sequenceを
versioned manifestへ保持する。同じgenerationのentry checkpointも
`generations/<generation>/checkpoint.json`へ置き、generation directory外へ状態本体を分散させない。
manifestと各segmentは処理済みFSEvents event ID/store UUIDも束縛する。checkpointは採用済みjournal headを示す
`journalHeadDigest`と両sequenceをancestor参照として保持し、delta record本体を内包、複製、破壊消費しない。
各segmentは`previousSegmentDigest`を持ち、manifestはgenesis digestと現在head segment digestを指す。

各generation directoryはimmutable `GENERATION` descriptorを持ち、root/exclusion/generation/schema bindingを固定する。
root直下でactive generationを選ぶ状態はchecksum付き`CURRENT` pointer一個だけとし、pointerは
generation IDと`GENERATION` descriptor digestだけを持つ。可変な最新checkpoint又はjournal manifest digestをpointerへ埋め込まず、
通常append/checkpoint更新でgeneration cutoverを発生させない。directory列挙、最大generation名、mtime、checkpoint単体、
journal単体をactive判定へ使わない。

sequenceは次の意味に分離する。

- `observationSequence`: 除外後に照合したdirty candidateごとに必ず1増える。semantic changeが無い照合も消費する。
  ADR 0004の`ws2` cursor末尾はこのsequenceであり、「ここまでのOS観測を照合済み」というwatermarkを表す。
- `semanticDeltaSequence`: create、modify、delete、renameのimmutable delta recordが生じた時だけ1増える。各deltaは一意の
  `observationSequence`と`semanticDeltaSequence`を持つ。一つのobservationはsemantic deltaを0件又は1件だけ生成し、
  directory hintから複数pathを照合する場合はpathごとのobservationへ展開してからsequenceを割り当てる。
- `noOpWatermark`: semantic deltaを生成しなかった連続observationの終端を永続化するrecordである。
  observation範囲と直前semantic delta sequenceを持ち、cursorだけ進んだ事実をrestart後も再現する。changeではないため
  `changes`件数と`semanticDeltaSequence`を増やさない。

これにより`change_limit`で各semantic deltaの直後にcursorを切れ、同じobservationの途中を指すcursorを作らない。
resultの`observedEvents`は`fromCursor`から返却cursorまでに進んだobservation数、`returnedChanges`は同区間のsemantic
delta数である。`omittedChanges`はresultをlinearizeしたjournal headまでに残るsemantic delta数とし、独立再計算できる。

### 3. durable append、restart、retention

publish単位は、連続するobservation、semantic delta、no-op watermarkを含むchecksum付きimmutable segmentとする。
runtimeはsegmentを同じdirectoryの一時fileへ完全encodeし、file `fsync`、atomic rename、directory `fsync`を行った後、
segment digestと新headを含むmanifestを同じ手順でatomic replaceする。manifest commitの完了を
`WorkspaceDeltaJournal.append`のlinearization pointとし、それより前にin-memory headを進めたりwaiterをwakeしたり、
処理済みFSEvents watermarkを公開したりしない。複数observationは一回のdurable commitへbatchできるが、durabilityを
省略して低latency成功に見せない。

segment又はmanifestのencode、write、`fsync`、renameに失敗した場合は`WORKSPACE_JOURNAL_WRITE_FAILED`で、そのrootの
active waiterを失敗させる。未commitの一時fileとmanifestから参照されない将来segmentは公開履歴ではなく、再起動時に
採用しない。最後にjournalへcommit済みのFSEvents watermarkからobserver replayできる状態を保ち、orphanを成功証拠へ昇格したり、
失敗したappendをmemoryだけでpublishしたりしない。

restart時はmanifest schema、root/exclusion/generation binding、manifest checksum、segment digest、segment間の
observation/semantic delta sequence連続性、no-op watermark、FSEvents watermark単調性を検証してからjournalを復元する。
checkpointが参照する`journalHeadDigest`は現在headと同一又は`previousSegmentDigest` chain上のancestorでなければならない。
現在journalがcheckpointより先なら、checkpoint head後のsemantic delta/no-op watermarkを順にreplayしてentry indexとcursor headを
復元し、observerはjournal側の最後にcommit済みevent IDから再開する。journal commit後・checkpoint更新前のcrashをcorruptionへ
誤分類せず、同じeventを二重publishしない。ancestorでない参照、checkpoint headより後の必要segment欠落、replay不可能なrecordは
corruptionである。
欠落、改変、不連続、未知major versionは`WORKSPACE_JOURNAL_CORRUPT`又は`WORKSPACE_JOURNAL_UNSUPPORTED`でfail closedし、
valid prefixへのtruncate、現在entryからの履歴再構成、silent full scanを行わない。callerが明示full snapshotを成功させた時だけ
後述のgeneration cutoverで新generationの空journalとcheckpointを初期化できる。

retentionはmanifestに固定したversioned policyに従い、commit済みのsealed segment全体だけをevictする。checkpointが参照中の
segmentと、そこから現在headまでのchainは削除対象にしない。先に新manifestへ
retention floorをcommitし、その後に旧segmentを削除する。削除失敗はspace leakとしてactivityへ記録できるが、新manifestの
floorより古いsegmentを再び公開しない。floor以前のcursorは`CURSOR_EXPIRED`である。active waiterの有無やconsumerの完了を
retention判断へ使わず、waiterを永続ackとして登録しない。

### 4. root writer lease

root stateを変更できるprocessは、root storeごとの`WorkspaceWriterLease`を取得した一つだけとする。leaseは
`RuntimeStore.baseDirectory/workspaces/<root_digest>/WRITER.lock`の固定inodeに対するkernel-backed exclusive advisory lock
（macOSではopen file descriptorへ保持する`fcntl` write lock）で実装する。lock fileを取得中にrename/unlinkせず、file本文の
PID、時刻、owner labelは診断情報に限定して所有権根拠にしない。process crash又はdescriptor closeでkernelがlockを解放することを
正規のlease releaseとし、時刻だけでstale ownerを奪取しない。
lock fileは`O_CREAT | O_CLOEXEC | O_NOFOLLOW`、ownerだけが読書き可能なmodeで開き、初回作成時はroot store directoryを
`fsync`する。lease専用descriptorを他用途へ複製せず、別code pathのcloseでprocess単位lockを意図せず解放しない。

lease ownerだけが次を行える。

- FSEvents observerの処理済みwatermarkを進める。
- active generationのjournal segment/manifestとcheckpointを書き、retentionを進める。
- semantic delta/no-op watermarkをin-memory publishし、waiterをwakeする。
- full snapshot、v1 migration、generation directory構築、`CURRENT` cutoverを行う。

各mutationとwaiter wakeの直前に、取得時のdescriptorとowner tokenが現在も有効であることを検証する。leaseを取得できない別MCP
processは`WORKSPACE_WRITER_BUSY`を返し、独自observer、memory-only journal、polling fallbackを開始しない。既にcommit済みの
immutable artifact又はjournal historyを明示read-only modeで読むことはできるが、OS現在状態のfresh result、delta snapshot、
`workspace_wait`を返してはならない。

lease loss又はlock descriptor異常を検出したownerは、rootを直ちにfail-closed read-onlyへ遷移させる。進行中append/cutoverを
成功扱いせず`WORKSPACE_WRITER_LEASE_LOST`を返す。active waiterはrequest lifecycleの失敗として同errorで回収し、data-ready
wake又はcursor/resultを発行しない。新しいjournal write、checkpoint write、retention、data waiter wake、FSEvents watermark更新を
禁止し、旧ownerがmemory stateだけでleaseを再獲得したことにしない。
再開には新規lease acquisitionと、disk上の`CURRENT`、generation descriptor、checkpoint、journal chain、committed FSEvents
watermarkの全再検証が必要である。

generation cutoverでは、旧`CURRENT`のcompare読取りより前にleaseを取得し、pointer replace、root directory `fsync`、
`CURRENT`再読と参照先検証が完了するまで同じleaseを保持する。途中でrelease/reacquireしたり、compare結果を別ownerへ渡したり
しない。active generationの通常journal appendもsegment準備からmanifest commit、waiter wakeまで同じlease ownerが保持する。

### 5. generation cutoverとcrash recovery

新generationは`generations/`配下の一意なstaging directoryへ、checkpoint、delta journal genesis/segments/manifest、
各checksumを完全生成する。各fileを`fsync`し、staging directoryを最終generation名へatomic renameして
`generations/` directoryを`fsync`するまで、rootの`CURRENT`を変更してはならない。

完成後、旧`CURRENT`を読んでcompare対象を確定し、新pointerをroot直下の一時fileへ完全encodeしてfile `fsync`する。
旧pointerがcompare対象のままであることを確認してから、一時fileを`CURRENT`へatomic replaceする。このpointer replace一個だけを
generation cutoverのlinearization pointとし、checkpoint rename、journal manifest rename、memory上のgeneration変更を
別のcutover点にしない。replace後にroot directoryを`fsync`し、`CURRENT`を再読してchecksumとdescriptor digestを検証し、
選択されたgeneration内のcheckpoint/journal checksum、generation binding、相互head参照を検証してから
成功を返し、waiterを新generationへ登録する。

pointer replace成功後にroot directory `fsync`又は再読検証が失敗した場合、cutover済みか否かを旧generationへ丸めない。
`WORKSPACE_GENERATION_CUTOVER_UNKNOWN`を返してrootを再open検証までunavailableにし、そのprocess内で旧pointerへ書き戻したり
waiterを旧generationへ再登録したりしない。再openは実在する`CURRENT`だけを検証してactive generationを確定する。

旧generation directoryはcutover時に削除・上書きしない。新`CURRENT`のdirectory `fsync`と再読検証が成功し、versioned
generation retention policyが許可した後だけ、activeでないgenerationをdirectory単位で回収できる。active pointerが壊れている時に
旧generationへfallbackしたり、directory走査から「最新らしい」generationを選んだりしない。

restart時の裁定は次のとおりとする。

- journal/checkpoint一式が先行生成されても`CURRENT`が旧generationなら、旧generationだけがactiveである。未参照の完成済み又は
  staging generationはorphanとして隔離し、自動採用しない。
- generation directoryのfile/directory `fsync`前にcrashした場合、pointer replaceは未実行でなければならない。旧pointerから復元し、
  incomplete generationを有効証拠へ使わない。
- generation directory `fsync`後・pointer replace前のcrashも旧pointerから復元する。完成済み新generationの存在だけでcutoverしない。
- pointer replace後・root directory `fsync`前のcrashでは、restart後にfilesystemが返す`CURRENT`だけを候補とする。旧又は新のどちらでも
  そのpointerのchecksumと全参照digestを検証し、別generationからfieldを補わない。pointer欠落、decode不能、参照不整合は
  `WORKSPACE_GENERATION_POINTER_CORRUPT`又は`WORKSPACE_JOURNAL_CORRUPT`でfail closedする。
- root directory `fsync`後のcrashでは新pointerと新generationを復元する。pointer先行で新generationが未完成となる順序を実装上許さない。

pointerが新generationを指すのにcheckpoint又はjournalが欠落・corruptな場合も、保持済み旧generationへ自動rollbackしない。
callerの明示full snapshotだけが、別の完全なgenerationを同じprotocolで構築しpointerを再びcutoverできる。

### 6. v1 observation journalからのcutover

現行`aishell.observation-journal.v1`とcheckpoint v1からの移行は、一回限りの明示migratorで行う。入力checkpointの
payload hash、root/exclusion/generation、FSEvents continuityを先に検証し、`journal_events`が空で、checkpointの
`journal_sequence`以前がADR 0006どおり圧縮済みである場合だけ移行できる。

migratorはv1の論理generation IDを維持し、v1 `journal_sequence`を最初の`observationSequence`、semantic delta sequence 0、
retention floor同値とするgenesis/no-op watermarkを持つdelta journalと、
そのgenesis `journalHeadDigest`と両sequenceを参照するcheckpoint v2を新generation directoryへ生成する。
前節の全file/directory `fsync`とroot-level `CURRENT` pointer replaceだけをcutoverとする。成功後はv2だけへ書込み、v1との
dual write、v1からの暗黙再同期、旧cursorの別generationへの付替えを行わない。
legacy v1には`CURRENT`が無いため、compare対象は「pointer absent」とし、migratorが再確認した時もabsentの場合だけ一時pointerを
`CURRENT`へatomic no-replaceする。macOSでは`renameatx_np(..., RENAME_EXCL)`又は同等の同一directory atomic primitiveを使い、
通常renameの上書き挙動へfallbackしない。`EEXIST`なら新pointerを書かず、既存`CURRENT`を検証してmigrationを再判定する。

v1 `journal_events`が残る場合は、過去のsemantic deltaを現在entryから正確に復元できないためmigrationしない。
`RESCAN_REQUIRED`を返し、callerの明示full snapshotで新generationを作る。migration途中の失敗は
`CHECKPOINT_MIGRATION_FAILED`としてv1 checkpointを有効なまま残し、半分だけv2へ切り替えない。cutover後にv1 artifactを
削除する場合も、v2 checkpointとjournalの再読検証成功後だけとする。

### 7. immutable delta fan-out

workspace runtimeはFSEvents callbackを直接waiterへ配らず、rootごとの単一actorで次を行う。

1. callback batchから除外pathを落とし、同じrelative pathへのdirty hintをcoalesceする。
2. OSの現在状態をidentity、metadata、必要なcontent SHAで照合し、rename/deleteをADR 0004の規則で確定する。
3. 確定したsemantic change又はno-op watermarkを`WorkspaceDeltaJournal`へdurable appendする。
4. manifest commit済みsequenceを待つ全waiterを起こし、各waiterのcursorから独立にretained sliceを導出する。

publish後のrecordを後続eventで書き換えない。renameは旧新pathを一recordで保持し、同じpathへの複数hintは照合前だけ
coalesceできる。consumerごとの配列生成、timeout、cancelはjournalを破壊せず、他consumerの可視範囲を進めない。
`workspace_snapshot`と`workspace_wait`は同じdurable journalを読むが、どちらも「読んだ」ことを理由にrecordを即時削除しない。
retentionはroot単位のversioned policyだけで進め、最も遅いwaiterを永続ackとして保持したり、waiter終了をGC条件にしたりしない。
cursorより新しいrecordがretentionから落ちた場合は`CURSOR_EXPIRED`であり、現在entryから履歴を再構成しない。

waiter登録は、cursor検証、retained slice確認、登録、journal head再確認を同じactorのlinearized operationとして行う。
「空を確認した直後、登録前に変更がpublishされた」lost wakeupを許さない。rootごとの待機数には明示上限を設け、超過は
`WAIT_CAPACITY_EXCEEDED`とし、既存waiterを追い出したりpollへsilent fallbackしたりしない。

### 8. gap、cursor、freshness

request開始時とwake後のresult確定直前に、root identity、exclusion digest、generation、sequence、journal retentionを検証する。
別root、別除外規則、別generation、未来sequence、形式不正、retention失効はADR 0004どおり`CURSOR_EXPIRED`とする。
同じpathのroot置換は`RESCAN_REQUIRED`である。

FSEventsのMustScanSubDirs、UserDropped、KernelDropped、EventIdsWrapped、RootChanged、volume UUID不一致、event ID連続性不能を
検出した時は、通常deltaの有無より`RESCAN_REQUIRED`を優先する。runtimeはrootをrescan-requiredへ一度だけ遷移させ、
そのrootのactive waiterをすべて同じgeneration/reasonで失敗させる。以後の`workspace_wait`とdelta snapshotも、callerが
`workspace_snapshot`で明示full snapshotを成功させ新generationを発行するまで同errorを返す。

`workspace_wait`自身はfull scan、checkpoint再構築、旧entryからの差分推測を行わない。gap前に保持していたdeltaだけを返して
成功扱いにしたり、timeoutへ丸めたり、別backendやpollingへfallbackしたりしない。完全性を証明できない時は待機時間に関係なく
fail closedする。

### 9. cancellationとMCP並行受付

MCPの`notifications/cancelled`で対象request IDが取消された時は、そのrequestに対応するwaiter registrationとtimerだけを
解除し、待機taskを終了する。tool固有のcancel ID、永続run handle、filesystem側の取消状態は作らない。cancelはjournal、cursor、
checkpoint、他waiterを変更しない。clientが再開する時は、保持している元cursor又は最後に受領したcursorで新しいrequestを送る。

change publish、deadline、cancelが競合した時はroot actor上の最初のterminal transitionだけを採用する。

- changeが先なら`changed` resultを一度だけ返す。
- deadlineが先なら`timeout` resultを一度だけ返す。
- cancelが先ならMCP request cancellationとして終了し、tool success resultを捏造しない。

後着eventは通常どおりjournalへ残り、後着timer/cancel callbackはno-opにする。server shutdown又はclient切断は全waiterを
cancelし、journalを進めず、detached taskとtimerを残さない。待機requestは接続を越えて復元しない。復元対象はworkspace journalであり、
request lifecycleではない。

MCP serverはstdio frameの読取り・parse・request routingを継続し、各requestをbounded child taskとして受付ける。
`workspace_wait` handlerをawaitしてreader loopを占有してはならない。workspace actorは状態遷移だけを直列化し、待機中に
`notifications/cancelled`、別rootのwait、`run_observe`、artifact query、通常tool requestを受理できるようにする。
同じrequest IDへのresponseは最大一回とし、connection writerでframe単位にserializeする。

この並行受付seamはACE-040の非同期process契約と共有し、ACE-044で一つのMCP request schedulerとして実装する。
workspace専用reader loopやtoolごとの独立serverを増設しない。

### 10. benchmark cutover

凍結済みのrepresentative benchmark v1、request materializer、期待値は変更しない。v1 fixtureへ`workspace_wait`を
後付けしたり、既存`workspace_snapshot` requestを長時間待機へ読み替えたりしない。

統合計測は別schemaのbenchmark v2で追加し、同じ実行中に明示full `workspace_snapshot`から受領した実cursorを
`workspace_wait.cursor`へ渡す。fixtureにfabricated cursorや固定generationを埋め込まない。v2はpolling baselineの
snapshot call/model turn/wall timeとwait candidateを比較し、v1の凍結結果と混ぜて削減率を主張しない。

benchmark v2のtask集合、fixture、request、oracle、集計式はACE-044の統合実装へ着手する前に、独立したfreeze taskで
versioned artifactとして固定しなければならない。ACE-043は契約要件を決めるだけでfreeze完了を主張せず、ACE-044が
実装後の観測値に合わせてv2 fixture又は期待値を作成・変更してはならない。Lattice DAGにfreeze taskからACE-044への
hard dependencyが無ければ、ACE-044開始前にplan revisionで追加する。

## Verification contract

ACE-044は少なくとも次のfocused testを先行又は同一実装単位で固定する。

- retained changeありでは即時`changed`、変更なしではmonotonic deadline後に正常`timeout`、`timeout_ms=0`ではblockしない。
- 同じcursorから待つ2件以上のwaiterが、一回のpublishから同じimmutable deltaとcursorを受け取る。一方の完了又はcancel後も
  他方のresultとjournal retentionが変わらない。
- durable segment/manifestの各write、`fsync`、rename前後へfaultを注入し、manifest commit前にはwaiterがwakeせず、
  checkpoint watermarkも進まないことを確認する。commit後の再起動では同じdelta/no-op cursorを復元する。
- segment欠落・bit flip・checksum不一致・observation sequence又はsemantic delta sequence不連続・checkpointの非ancestor参照を
  `WORKSPACE_JOURNAL_CORRUPT`へ固定し、valid prefix truncate、memory-only publish、silent scan 0件を確認する。
- journal commit直後・checkpoint更新前にcrashさせ、ancestor checkpointからdurable delta/no-opを一度だけreplayし、journalの
  committed FSEvents watermarkからobserverを再開して二重publishしないことを確認する。
- semantic change、semantic no-op、directory hintからの複数path展開を固定し、`observationSequence`、
  `semanticDeltaSequence`、no-op watermark、`observedEvents`がrestart前後で一致する。
- waiter登録の直前・直後にeventを注入し、lost wakeup 0件にする。同path hintのcoalesce、rename、delete、semantic no-opを固定する。
- `change_limit` N/N+1でcursor、`omittedChanges`、`hasMore`を検証し、全page連結が単発完全結果と一致する。
- gapと通常changeを同じbatch及び前後raceで注入し、全active waiterと後続waitが`RESCAN_REQUIRED`になる。明示full snapshot成功後だけ
  新generationで待機を再開できる。
- retention失効、別root、root置換、別generation、未来sequence、形式不正をtyped errorで固定し、silent full scan 0件を確認する。
- change/cancel、timeout/cancel、change/timeoutを決定的barrierで競合させ、response最大一回、waiter/timer leak 0件、cursorの意図しない
  前進0件を確認する。
- 一件の`workspace_wait`を保留したまま、同じconnectionでcancel通知、通常`workspace_snapshot`、`run_observe`相当requestを処理でき、
  wire frameが混線しないことをMCP fixtureで確認する。
- server shutdownとclient切断で待機taskを回収し、再接続後に元cursorからretained deltaを取得できることを確認する。
- 空`journal_events`のvalid v1 checkpointは同generation/cursor watermarkを維持してv2へ一回だけcutoverする。残存event、
  migration fault、v2再読失敗はそれぞれ`RESCAN_REQUIRED`又は`CHECKPOINT_MIGRATION_FAILED`となり、v1を破壊せずdual writeしない。
- generation journal/checkpoint先行、generation directory `fsync`前後、pointer replace前後、root directory `fsync`前後の各barrierで
  crashさせる。restartは`CURRENT`が指すgenerationだけを選び、pointer未更新時は旧generationを維持し、pointer更新後は
  完成済み新generationを復元する。未参照directoryの自動採用と新旧field混成を0件にする。
- pointer replace後のroot directory `fsync`/再読失敗は`WORKSPACE_GENERATION_CUTOVER_UNKNOWN`となり、旧generationへrollbackせず、
  再open時の`CURRENT`検証だけで確定する。pointer checksum不正、参照欠落、digest不一致はfail closedし、保持済み旧generationへ
  fallbackしない。cutover直後に旧generation directoryが保持されていることも確認する。
- 二つ以上の独立MCP processを同じrootへ接続し、一つだけがwriter leaseを取得する。他processは
  `WORKSPACE_WRITER_BUSY`となり、observer開始、journal/checkpoint write、waiter wake 0件であることを確認する。
- lease ownerをjournal segment準備中、manifest commit直後・wake前、`CURRENT` compare後、pointer replace後の各barrierでcrash又は
  lease-lossさせる。旧ownerは追加write/wakeせず、kernel release後の新ownerが全disk stateを再検証し、committed watermarkから
  一度だけ再開する。manifest commit済みdeltaは新requestから取得でき、未commit deltaを成功へ昇格しない。
- lease loss後はretained immutable readだけが明示read-onlyとして利用でき、fresh snapshot/delta/waitは
  `WORKSPACE_WRITER_LEASE_LOST`又は`WORKSPACE_WRITER_BUSY`となる。memory stateだけの再獲得とsilent pollingを0件にする。
- legacy `CURRENT` absent migrationへ複数processを同時接続し、一件だけがlease ownerとしてatomic no-replaceを実行し、他processは
  busyになることを固定する。owner crash/release後に取得したprocessは既存pointerを再検証し、migrationを再実行・上書きしない。
- absent再確認後・atomic no-replace直前に`CURRENT`出現を注入し、`EEXIST`時はpointerを上書きせず再読検証することを固定する。
- retention後もsnapshotと複数waiterがfloor以後を独立再生でき、floor以前だけが`CURSOR_EXPIRED`になる。
- 凍結benchmark v1のfixture/materialized request/digestが不変であることを確認する。ACE-044にhard-dependする事前freeze taskが
  benchmark v2のfixture/request/oracle/集計式を固定し、v2だけがfull snapshotから得た実cursorをwait requestへ渡す。

docsだけを固定するACE-043ではSwift testを実行せず、Markdown構造、schema名、ADR 0004/0006とのcursor・gap規則の整合、
git diffをfocused verificationとする。runtime・MCP wireを変更するACE-044では上記focused suiteに加え、initialize、tools/list、
成功・timeout・gap・cancel response fixtureを確認する。

## Consequences

`workspace_wait`により、AI hostは変更がない間のsnapshot pollとmodel turnを削減できる。代わりに
`WorkspaceDeltaJournal`は独立したdurable ownerとなり、single-consumer queueではなくretained immutable logとして
snapshot/wait双方のcursorから安全にfan-outできなければならない。
この内部refactorは履歴保持を強めるもので、既存snapshot、checkpoint、cursor error、default/full profileの機能を削減しない。

ACE-044は`AIShellCore`へwait registryとimmutable delta fan-out、`AIShellMCP`へ共有request schedulerとcancellation bridgeを実装する。
MCP handlerへFSEvents照合やjournal所有を埋め込まない。待機の便利さを理由にevent gap、retention失効、root置換を成功へ丸めず、
性能上の都合でpolling又はsilent rescanへ退行しない。
