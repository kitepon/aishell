# ADR 0017: apply change set契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-21
- Amended: 2026-07-23 (ACE-053 public cursor/client integration)
- Lattice task: `ACE-050`
- Control: `aishell-capability-expansion-20260721`

## Context

現行の`files_write_text`、`files_move`、`files_trash`は一回の呼出しにつき一項目だけを変更する。複数fileを編集するAI hostは、
各fileのSHA確認、変更、失敗時の逆操作、再snapshotを自分で反復するため、途中失敗や外部編集との競合で一部だけが反映され、
成功した変更とworkspace cursorの対応も失われる。単に既存primitiveを順に呼ぶwrapperでは、この部分成功を解消できない。

Phase 5では、AIShellが一つの許可root内のregular fileに対するcreate、write、delete、renameをdurable transactionとして所有する。
事前状態はcontent SHA-256又は明示的なabsenceで固定し、filesystemのcommit、完全diff evidence、workspace runtimeのknown mutationを
同じtransaction IDへ束縛する。これはAI hostの汎用patch言語、Git commit、directory tree操作を再実装するものではない。

## Decision

### 1. 公開境界

default development profileへ`apply_change_set`を追加し、成功schemaを`aishell.apply-change-set.v1`とする。
requestは次を必須にする。

- `path`: `workspace_snapshot`と同じ許可root。
- `workspace_cursor`: ADR 0004のopaque `ws2` cursor。対象root、exclusion規則、generation、呼出側が確認したjournal位置を束縛する。
- `changes`: 1〜128件の順序付き配列。各要素は一意なcaller指定`change_id`と、次のclosed unionのいずれかである。
  - `create`: `path`、`expected: { state: "absent" }`、`content`。
  - `write`: `path`、`expected: { state: "file", sha256 }`、`content`。
  - `delete`: `path`、`expected: { state: "file", sha256 }`。
  - `rename`: `source`、`source_expected: { state: "file", sha256 }`、`destination`、
    `destination_expected: { state: "absent" } | { state: "file", sha256 }`。`state=file`ではSHA-256を省略できない。
- `content`: `encoding: utf8 | base64`と`data`。decode後のbytesを正本とし、改行やUnicodeを正規化しない。
- `diff_byte_budget`: 通常resultへ埋め込む完全item単位のpreview budget。1〜1,048,576 bytes、既定65,536。
- `retention_seconds`: 完全diff artifactの保持要求。実装のversioned最小・最大範囲外は丸めず`INVALID_ARGUMENT`とする。

`client_id`、`client_epoch`、`request_sequence`と内部transaction cursorはMCP serverが所有し、model-visible inputへ出さない。
serverは`workspace_cursor`以後のdeltaが空であることを共有`WorkspaceStateRuntime`で確認してから、そのrootの内部transaction cursorへ
一度だけ変換する。成功resultは入力`workspace_from_cursor`とknown mutation反映後のopaque `workspace_cursor`を返すため、callerは
確認用snapshotを追加しなくてよい。staleなworkspace cursorを最新内部cursorへsilent置換して適用してはならない。

全pathはcursorが束縛する一つのcanonical rootからのrelative pathとして解決する。absolute path、`..` escape、root自体、
symlink又はsymlinkを含むancestor、socket、device、FIFO、package／directoryを変更対象にしない。対象外の種類は
`UNSUPPORTED_CHANGE_TARGET`で全transactionを拒否する。既存20 primitiveはfull profileに維持し、directoryや単項目操作の
互換経路を削除しない。

`changes`は一つの最終filesystem graphとして検証する。canonical pathごとにconsumerとproducerはそれぞれ最大一つ、
同じsourceを二度消費せず、作成・更新後の同じdestinationを二度生成しない。rename先が開始時に存在する場合は、そのpathが同じ
transaction内でrename又はdeleteのsourceとして一度だけ消費され、指定SHAが一致する場合に限る。これによりrename chainとcycleを
staging経由で扱える。順序依存の上書き、case-fold／Unicode正規化後に衝突するpath、親子pathの混在、自己rename、同一file identityを
別名から二重指定するrequestは`CHANGE_SET_CONFLICT`で拒否し、配列順から意図を推測しない。

decode後contentは一件16 MiB、合計64 MiBをv1上限とする。件数、path、content、diff admissionの上限超過は
`CHANGE_SET_LIMIT_EXCEEDED`であり、先頭だけを適用しない。

idempotency stateはroot bootstrap時に作る固定64 client slotだけを持つ。各slotはroot identityへ束縛した不変のstable `client_id`、
`slot_generation`、`allocation_state: free | active`、`current_epoch`を持ち、active時だけ`client_high_water`と現在epochの
直近256 sequenceの固定長replay ringを持つ。各ring slotはsequence、canonical request digest、
transaction ID、state、terminal response digest、artifact handle／expiryを持つ。request digestはidentity 3 fieldを除くschema version、
cursor、changes、content bytes、budget、retentionを決定的に束縛する。

Coreの明示client APIはclient slotを暗黙作成しない。固定slotに存在しない`client_id`は`CHANGE_SET_CLIENT_NOT_REGISTERED`とする。
公開MCP adapter自身はrootごとのdurable clientであり、最初の`apply_change_set`時にactive slotがなければ最小free slotを一度だけ
managed clientとして確保する。再起動後はactive slotとhigh-waterを復元し、新slotやsequence 1を増殖させない。
既知slotではrequest epochが`current_epoch`より小さければ旧epochの個別request recordを一件も保持せず`CHANGE_SET_EXPIRED`、大きければ
`CHANGE_SET_CLIENT_EPOCH_AHEAD`、同じでもallocation stateがfreeなら`CHANGE_SET_EXPIRED`とする。activeかつepoch一致時だけsequenceを調べる。
epoch最初の新規sequenceは1、以後は
`client_high_water + 1`だけを許す。それより大きければ`CHANGE_SET_SEQUENCE_GAP`、一つ前のrequestがnonterminalなら
`CHANGE_SET_PREVIOUS_PENDING`とし、順番を飛ばしてadmitしない。

`replay_floor = max(1, client_high_water - 255)`とする。受信sequenceが`replay_floor...client_high_water`なら対応slotを必ず読み、digest一致で
pending transactionへ合流又は保持中の同じterminal responseをreplayし、digest不一致は`CHANGE_SET_SEQUENCE_CONFLICT`とする。
この範囲のslot欠損やsequence重複は`CHANGE_SET_STORE_CORRUPT`である。sequenceが`replay_floor`未満なら個別request recordを保存せず、
high-waterだけから`CHANGE_SET_EXPIRED`と判定する。古いopaque key／request tombstone、Bloom filter、時刻からの推測へfallbackしない。
ring内でもterminal payload又はartifactのretentionが終了していれば`CHANGE_SET_EXPIRED`を返し、同じsequenceを新規適用しない。
既存sequenceのlookup、digest照合、replay／expired判定はcursor、expected SHA、quotaを再検証する前に行う。commit後には当然古くなる
元cursorやbefore SHAを理由に正しいretryを拒否せず、新規sequenceだけを後続の全validationへ進める。

clientは初回送信前に`client_id`、`client_epoch`、現在sequence、同じschema値を再送できる完全request payloadを自身のdurable
in-flight stateへ保存し、terminal responseを受け取るまで同じpayloadだけをretryする。serverだけがcanonical digestを計算し、callerへ
独自canonicalizerを要求しない。terminal受領後にだけ次sequenceへincrementしてin-flight stateをatomic replaceする。validation又はquotaで
admit前に拒否されたresponseを受け取った時は、epoch／sequenceを維持したまま修正版payloadへreplaceしてよい。

client process／app再起動は同じclient ID、epoch、in-flight stateを復元する。client stateを失った又は意図的にresetする場合は、ownerが
同じstable client IDのepoch rotationを承認し、成功receiptをdurable保存してから新epochのsequence 1を使う。新UUIDを増殖させたり、
owner承認なしに同じepochのsequenceを1へ戻したりしない。stable client IDはretire後も同じ固定slotに残り、owner承認付きregistry
reinitialize又はroot identity置換まで変更しない。epochとringはTTL evictionしない。client ledgerは64 slot × 256 fixed ringとbounded terminal envelopeの最大byte数をroot
bootstrap時にquota確保し、途中でslot又はringを可変増加させない。

#### Owner control plane

ownerが行うepoch rotation、retire、registry reinitialize、abortは公開MCP toolではなく、macOS管理appのlocal owner control planeだけが
行うH操作である。公開MCP adapter自身の初回managed slot確保だけは、既に許可されたrootへの明示的なdestructive tool callに伴う
idempotency内部状態の作成であり、modelへcredentialを渡さずregistry actor上で行う。
control request schemaは次のclosed unionとする。

- `allocate`: `control_request_id`、`owner_proof`。最小番号のfree slotに既存のstable client IDを割り当てて返す。
- `rotate_epoch`: `control_request_id`、`client_id`、`expected_epoch`、`next_epoch=expected_epoch+1`、`owner_proof`。
- `retire`: `control_request_id`、`client_id`、`expected_epoch`、`owner_proof`。
- `reinitialize_registry`: `control_request_id`、`expected_registry_generation`、`owner_proof`。
- `abort_pre_side_effect`: `control_request_id`、`transaction_id`、`expected_phase_digest`、`owner_proof`。

`control_request_id`もcanonical lowercase UUID v4とする。`owner_proof`は管理appがownerの都度確認後に発行する5分有効・一回限りの署名receiptで、
proof ID、root digest、action、control request ID、client ID（allocate／reinitialize／abortではnull）、expected／next epoch、
expected registry generation、transaction ID／phase digest、expiryを束縛する。AIShell state directoryのsecretで
認証し、MCP result、log、artifactへsecret又は生proofを出さない。期限切れ、改ざん、別root／actionへの流用は
`CLIENT_OWNER_PROOF_INVALID`であり、UI clickの有無やprocess UIDだけからowner承認を推測しない。

root client registryは固定64 slot、単調増加`slot_generation`、固定128件のowner-control receipt ringを一つのdigest付きfileとして
atomic replaceする。各stable client IDはslot作成時に一度だけ生成し、retire／再allocationで変更又は別slotへ移さない。allocateはfree slotが
ある時、最小slot番号のepochを1増加し、active、high-water 0、空ringへ切り替えて、そのslotの既存client IDと新epochを返す。
free slotがなければ`CHANGE_SET_CLIENT_CAPACITY_EXCEEDED`とretire可能slot一覧を返し、上限を増やしたりactive slotを
自動evictしたりしない。

rotationはclient registry actor上でapply admissionと直列化し、`expected_epoch == current_epoch`かつそのclientのnonterminal transactionが
0件の場合だけ、同じslotの`current_epoch`を1増加、high-waterを0、replay ringを空へ一つのatomic replaceで切り替える。旧epochの
request／digest／responseは保存せず、以後の旧epoch applyを現在epochとの比較だけで`CHANGE_SET_EXPIRED`にする。最大epochからのrotationは
`CLIENT_EPOCH_EXHAUSTED`とする。最大epochのfree slotも再allocateせず、他のretire可能slotを使うか、owner承認付きroot client registry
reinitializeを使う。apply admissionが先にlinearizeした競合rotationは
`CLIENT_ROTATION_BLOCKED`、rotationが先なら旧epoch applyはexpiredとなる。

retireも`expected_epoch`一致、nonterminal transaction 0件だけで、stable client IDとcurrent epochを残したままslotをfreeへ戻し、
high-water／ringを消去して`slot_generation`を増加させる。条件未充足は
`CLIENT_RETIRE_BLOCKED`とする。retained artifactはhandleで
期限まで読めるがapply replayは終了する。free中のold client stateからのapplyは個別tombstoneなしに`CHANGE_SET_EXPIRED`で、新しいclient
allocationへ暗黙変換しない。次のallocateは同じ固定slot／client IDのepochを増やすため、old epoch requestは現在epochとの比較だけで
expiredになる。満杯時はownerがterminalなslotをretireして同じ固定slotをallocateへ再利用できる。全slotがnonterminalなら各transaction IDと
正規recovery操作を返し、回復／終端後にretire可能にするため、capacityを恒久blockerにしない。

`reinitialize_registry`は全transactionがterminal、全64 slotがfree、`expected_registry_generation`一致の時だけ実行できる。それ以外は
`CLIENT_REGISTRY_REINITIALIZE_BLOCKED`とactive client／transaction一覧を返す。成功時はregistry generationを1増加し、64個すべての
stable client IDを新しいUUID v4、epoch 0、free、空ringへ同じatomic replaceで更新する。旧client ID／epoch requestは
`CHANGE_SET_CLIENT_NOT_REGISTERED`となり、暗黙allocationしない。これはepoch exhaustionからの明示回復だけで、client上限に達するたび
実行したり、active clientを追い出したりしない。

同じclientへのcontrol操作とapply admissionは単一registry actorでlinearizeする。同じ`control_request_id`のretryはcontrol receipt ringから
同じresultを返し、異なるrequest IDで同じ`expected_epoch`を競合させた場合は最初のatomic replaceだけが成功し、後続は
`CLIENT_EPOCH_CHANGED`となる。unexpired receiptをringからevictせず、128件すべてが5分以内なら新control admissionを
`CLIENT_CONTROL_CAPACITY_EXCEEDED`で待たせる。これは時間経過又は同じrequestのretryで解消可能で、slot上限を増やす理由にしない。
control receiptはcontrol request ID、proof ID digest、action、result digest、更新後slot generation／current epoch、expiryだけを持ち、旧epochの
apply request、high-water、ring、expected epochを保存しない。expiry後の同control requestは期限切れowner proofにより
`CLIENT_CONTROL_EXPIRED`となり、操作を再実行せず、ownerは現在registryを確認して新proof／request IDで次操作を選ぶ。

client-registry control（allocate／rotate／retire／reinitialize）のcrash orderingは、
(1) owner proof／expected epoch／nonterminal 0件のread-only検証、(2)新registry imageとcontrol receipt生成、
(3) proof ID消費、slot更新、receipt追加を含む単一fileのwrite・fsync・atomic replace・directory fsync、(4)response、の順だけを許す。
(3)より前のcrashは旧registryのままで同proofをretryでき、(3)後のresponse喪失は同じcontrol request IDからreceiptをreplayする。
slot更新とproof消費を別fileへ分けず、crash後にepochだけ進める、free slotだけ失う、同proofを二重使用する状態を作らない。

#### Durable request reservationとadmission

新規sequenceはschema／client allocation／epoch／sequence／path graph／cursor／capability／全expected state／全SHAをread-onlyで検証した後、
request全体を`aishell.apply-change-set-reservation.v1`としてcanonical化する。headerはRFC 8785 canonical JSONで、schema version、root path／
device／inode／digest、client ID／epoch／sequence、cursor、canonical relative path bytes、change graph、expected state、content descriptor、
budget、retentionを持つ。各content descriptorはchange ID、連結順、offset、length、SHA-256を持ち、decode後の全content bytesをrequest順に
連結した`content.bin`から一byteも省略しない。
各pathは入力JSON stringを正規化せずUTF-8 encodeした`path_utf8_base64`とbyte lengthで表し、source／destinationの区別とrequest順をheaderへ
固定する。base64再decode不能、length不一致、別Unicode正規形への置換を同じpathとして受理しない。

plaintext request digestは
`SHA-256("aishell.apply-change-set-reservation.v1\0" || UInt64BE(header_length) || header_bytes || UInt64BE(content_length) || content_bytes)`
とする。EvidenceStoreのprivate reservation recordはreservation ID、root／client／epoch／sequence binding、header／content／total length、
各SHA-256、request digest、quota reservation ID、producer boot／lease IDを持つ。headerとcontentは一つのAES-256-GCM plaintextとして暗号化し、
CSPRNG生成のkey内一意な96-bit nonce、key ID、ciphertext length、authentication tagをrecordへ固定する。鍵はmacOS KeychainのAIShell state
keyだけを使い、active／recovery reservationが参照する旧key IDをkey rotationで削除しない。nonce再利用又は鍵取得不能なら
`CHANGE_SET_SECRET_STORE_UNAVAILABLE`としてreservationもadmissionも作らない。fileとparent directoryはowner-onlyとし、plaintext、key、
content、expected bytesをlog、activity、MCP error、telemetryへ出さない。reservationは公開artifact handleを持たず、`artifact_read`から読めない。
AES-GCM additional authenticated dataはreservation schema、reservation ID、root digest、client ID／epoch／sequence、header／content length、
request digestのRFC 8785 bytesとし、recordだけの差替えもauthentication failureにする。

Section 7のquota計算はcanonical header、全content bytes、暗号化overhead、rollback、stage、journal、Trash backup、diff、terminal envelopeを
実byte数で含める。EvidenceStoreはまず`reserved_unadmitted` allocationと暗号化payloadをwriteし、decrypt、AEAD tag、length、全digest、bindingを
再検証してfile／directoryをfsyncする。これ以後reservation payloadはimmutableで、field補完、content再取得、caller retryによる差替えを
行わない。容量不足又はKeychain失敗はclient high-waterを進めずworkspace副作用0件で終了する。

durable admissionは、このreservation fsync後かつtransaction directory作成又はstaging writeを含む最初のrequest固有filesystem副作用の
直前に行う。current client epochの再照合、client high-waterのincrement、replay slot、transaction ID、request digest、immutable
reservation ID／length／digest／bindingを一つのatomic registry recordとしてwrite、fsync、atomic replace、directory fsyncして初めて成立する。
admissionはclientが再送したrequestを参照せず、reservation recordだけをmaterialization正本にする。

新規requestのdurable orderingは次だけを許す。

1. read-only validationとexact quota計算を完了する。
2. `reserved_unadmitted` allocation、完全canonical envelope、全content bytesを暗号化してwrite／自己検証／fsyncする。
3. high-water／ring slot／transaction IDからimmutable reservationを参照するadmissionをatomic save／fsyncする。
4. serverがreservationをdecrypt／再検証し、transaction directoryとstageをmaterializeする。

step 2より前のcrashは永続状態なし、step 2と3の間はunadmitted orphan、step 3と4の間はserverだけでmaterialize可能なadmitted transactionと
なる。順序を入れ替える、digestだけを保存する、stage作成後にadmissionを事後記録する、client再送が来るまでnonterminalを放置することを
禁止する。MCP cancellation、response喪失、client process／state消失はtransaction cancelではなく、server recoveryが同じreservationから
完遂又はpre-side-effect abortへ進める。同じclient／epoch／sequence／digestのretryは同じ実行へ合流するだけである。

unadmitted reservationはactive request lease中だけpinする。正常なvalidation／CAS失敗ではその場で削除し、crash recoveryでは全client
registryと予約namespaceを先に走査し、同じreservation IDのadmissionもtransaction directoryもないことを確認してreleaseする。同じbootで
leaseだけを失ったrecordは10分後に同じ照合を行い、古いboot IDのrecordはstartup時に行う。存在確認不能、binding不一致、registry読取不能を
orphan扱いで削除しない。admitted／recovery_required reservationはTTL、LRU、quota pressureでevictせず、terminal responseとreplay slotが
durableになった後だけencrypted request materialを削除し、ringにはrequest digestとterminal resultだけを残す。通常のcommitted／rolled back／
precondition abortではterminal registry save後にmaterialを削除してreservation quotaをreleaseする。corruption abortではciphertextをowner-only
quarantineへ24時間pinし、digest／length／causeだけをevidenceに残して期限後に削除する。`recovery_required`は期限なしでpinし、ownerが
回復又は安全なpre-side-effect abortを完了する前に秘密materialをGCしない。いずれもplaintextをquarantine又はerrorへ複製しない。

recoveryはreservation ID、root／client／epoch／sequence、length、AEAD tag、header／content SHA、request digestをadmissionと相互照合する。
tamper、truncation、別reservation差替え、decrypt失敗、descriptor range重複／欠落、content SHA不一致は
`CHANGE_SET_RESERVATION_CORRUPT`でfail closedし、caller bytes、workspace現況、diffからrequestを再構成しない。target pathへの副作用が未開始と
証明できる場合だけ、terminal `aborted_before_side_effect`とcorruption evidenceをdurable replay slotへ保存してreservationを隔離できる。
副作用開始の有無又はnamespace integrityを証明できなければ`recovery_required`としてciphertextとquotaをpinする。

admission後はimmutable reservationからroot、epoch、cursor、parent identity、expected SHAをもう一度照合する。競合、root置換、capability
失効、materialization quota不一致をtarget path変更前に検出し、transaction journalが`commit_decided`未満かつtarget mutation receipt 0件なら
terminal `aborted_before_side_effect`としてtyped cause、変更0件、同じclient／epoch／sequenceのreplay resultを保存する。内部stageだけがあれば
digest照合後に削除できる。target mutation receiptが一件でもある、`commit_decided`済み、又はabsenceを証明できない場合はabortへ丸めず
通常recoveryを続ける。

client stateを失ったownerがepoch rotationを要求しても、server recovery中はtransaction IDとstateを返してrotationをblockする。serverは
clientなしでterminalへ収束し、ownerはterminal確認後にrotationできる。reservation keyの恒久喪失又はpre-side-effect corruptionでは、local
owner control planeの`abort_pre_side_effect`（control request ID、transaction ID、expected phase digest、owner proof）だけを許す。
transaction journal、namespace、target mutation receiptから`commit_decided`未満かつtarget変更0件を証明できた時だけ、internal materialを隔離し、
terminal abort、replay slot、quota releaseを一つのrecovery transactionで確定する。証明不能なら拒否し、owner承認をpartial writeの破棄へ
流用しない。これによりadmission済み・client喪失だけを理由とするnonterminal deadlockを残さない。

owner abortのlinearization pointは、control request ID、proof ID digest、expected phase digest、target mutation receipt 0件の証明を持つ
`owner_abort_decided`をtransaction journalへappend／fsyncした時点である。それ以前のcrashは操作なしで同proofをretryでき、それ以後は
server recoveryがreservation隔離、`aborted_before_side_effect` terminal replay slotとcontrol receiptのregistry atomic save、quota releaseを
順に完遂する。registry save後／quota release前のcrashは同じterminal resultを保ったままreleaseだけ再実行する。proof消費を推測せず、
transaction journalとcontrol receiptの同じcontrol request IDでidempotentに照合する。

### 2. 予約namespaceとpath capability

各rootの`<root>/.aishell-transactions/`をvolume-local stagingとrecovery record専用の予約namespaceとする。許可rootをtransaction対応へ
設定するbootstrapで、requestをadmitする前に、
owner-only permission、namespace schema、canonical root path、root device/inode、nonceを持つmarkerを作成してfsyncする。markerがない
既存同名path、root identityが違うmarker、symlink、owner外permissionは`RESERVED_NAMESPACE_CONFLICT`で停止し、既存内容を隠す、
移動する、削除することはしない。

namespace versionはroot identityの補助bindingとexclusion digestへ含める。`files_*`、`workspace_snapshot`、`workspace_wait`、
`read_context`、`search_context`、Git context、profile／impact providerを含む全AIShell read、list、search、delta、artifact source、
変更targetからnamespace全体を不可視にし、明示path指定も`RESERVED_PATH`で拒否する。Git workerには明示exclude pathspecを渡し、
namespace eventはjournal sequenceへ入れない。これはAIShell公開面の不可視性であり、管理外のfilesystem clientやGit CLIから存在しないと
主張しない。

予約namespace追加はADR 0004のexclusion contract変更なので、旧exclusion digestのcursorを`CURSOR_EXPIRED`にし、旧checkpointから
entryだけを流用しない。未完の旧version transactionがある時は旧readerで先に回復し、active transactionが0件になってからだけ、
versionごとの純粋なnamespace migratorで新markerとlayoutを別名生成・検証・atomic swapできる。利用者fileと区別不能な既存path、
未知version、migration失敗は自動変換せず、明示full snapshotで新generationを作る前に解消を要求する。

root、各parent directory、namespaceはfile descriptorでpinする。rootから各path componentを`openat`＋`O_NOFOLLOW`で辿り、
`fstat`したdevice/inodeをmanifestへ記録し、commit/recoveryはpath文字列を再解決せず同じdirectory FDに対する`*at`系操作だけを使う。
process再起動後のrecoveryはroot FDから同じ手順でparent FDを開き直し、manifestのdevice/inodeと全componentが一致した時だけ操作する。
一致しなければ`recovery_required`とし、新しいdirectoryを旧FD相当と推測しない。
存在してはならないdestinationは`renameatx_np(RENAME_EXCL)`、既存objectとの置換／cycle退避は
`renameatx_np(RENAME_SWAP)`又は同等に事前検証したno-replace/swap primitiveを使う。必要なflag、directory fsync、同一deviceの
実動作はroot bootstrap時に予約namespace内のprobe objectで一度検証し、root identityとnamespace versionへ束縛したcapability receiptを
保存する。`apply_change_set`のvalidationはreceiptと現在root identityをread-onlyに再照合し、欠落・不一致・非対応なら
`TRANSACTION_CAPABILITY_UNAVAILABLE`で変更0件のまま停止する。request中にprobe副作用をadmissionより先行させない。
check後にpath-based `FileManager.moveItem`や上書きrenameへsilent fallbackしない。

### 3. cursorとpreflight

root actorはmutationを一件ずつ直列化し、transaction開始時にFSEventsを同期drainしてdirty pathをOSのidentity、metadata、
content SHAへ照合する。request cursorは形式が正しいだけでなく、この照合後のroot identity、exclusion digest、generation、
journal headと完全一致しなければならない。retention失効、別root、別generation、未来sequenceは`CURSOR_EXPIRED`、event gap、
drop、root置換は`RESCAN_REQUIRED`、同generation内でheadだけが進んでいれば`WORKSPACE_CHANGED`と現在cursorを返す。
古いcursorから現在状態を推測して適用したり、silent full snapshotで続行したりしない。

preflightはfilesystemを変更する前に全changeを解決し、次を一括確認する。

1. 全pathと予約namespaceが同じroot device上にあり、pinしたdirectory FDとno-replace／swap capabilityを利用できる。
2. `state=absent`のpathは存在せず、`state=file`はregular fileとして存在し、bytesのSHA-256が指定値と一致する。
3. canonical path、case-fold名、file identity、operation graphがSection 1の一意性を満たす。
4. 全after bytes、rollback copy、manifest、完全diff artifactに必要な実byte数がquotaへadmitできる。
5. root actorの照合後からcommit admissionまでに対象identity、metadata、SHA、親directory identityが変化していない。

期待したfileの欠落又はSHA不一致は`CONTENT_CHANGED`、期待したabsenceへの出現は`EXPECTED_ABSENCE_VIOLATED`、root外又は
別deviceは`ROOT_MISMATCH`／`TRANSACTION_VOLUME_MISMATCH`とする。一件でも失敗すればstagingを公開せず、変更0件で終了する。
SHA比較をmtime又はworkspace indexのcached hashだけで代用しない。

expected SHAとcursorはoptimistic concurrency controlであり、他processへ強制lockを掛けるsecurity boundaryではない。directory FDと
`RENAME_EXCL`／`RENAME_SWAP`はpath置換raceとsymlink再解決を閉じるが、管理外processが既に開いたfile descriptorからbytesを変更する
windowはmacOS上で閉じられない。commit直前、transaction slotへのcapture直後、各配置後、response直前にidentity、size、SHAを照合し、
観測できた競合だけをtyped errorにできる。最終照合後の管理外writeまで防いだ、又は全raceを必ず検出すると主張しない。

### 4. durable prepare、commit、rollback

transaction stateは`preparing | prepared | commit_decided | filesystem_committed | runtime_committed | trash_committed | finalized |
rollback_decided | rolled_back | aborted_before_side_effect | recovery_required`の単調なstate machineとする。
`aborted_before_side_effect`はtarget mutation receipt 0件かつ`commit_decided`未到達からだけ入れるterminal stateである。
transaction IDは一度発行したら再利用せず、
state、operation manifest、before/after/rollback SHA、path identity、cursor binding、各step receiptをcanonical encodingとdigest付きの
append-only journalへ保存する。未知state、digest不一致、step逆行は`CHANGE_SET_STORE_CORRUPT`で停止する。

prepareでは、予約namespace内のowner-only transaction directoryへafter bytesとrollback materialを作る。既存fileの置換用stageは
現在fileのmetadataを複製してからcontentだけを置換し、POSIX permission、ACL、extended attributeを意図せず失わない。
各fileを完全writeし、size／SHAを再検証してfileとdirectoryをfsyncする。delete対象の原本とrename sourceはrollback可能な形で
保持し、全materialとmanifestがdurableになるまで`prepared`を記録しない。prepare失敗はtransaction directoryだけを回収し、
workspaceを変更しない。

commitは次の規則に従う。

1. 全precondition、親directory identity、staged SHAを再照合する。競合があれば`rollback_decided`としてstageを破棄する。
2. 変更後状態を完遂できるdurable materialが揃った後にだけ`commit_decided`をfsyncする。
3. rename cycleを含む全sourceをtransaction-owned slotへ退避し、各destinationへafter objectをatomic renameで一件ずつ配置する。
   各切替の前後にstep receiptを永続化し、directoryをfsyncする。
4. 全pathの存在、identity、content SHAをfinal graphと照合して`filesystem_committed`を記録する。

`commit_decided`より前の通常失敗はrollbackし、全before pathとSHAを照合してから`rolled_back`を返す。
`commit_decided`後は成功予定状態がtransactionの正本であり、process crash又はI/O失敗からは同じreceiptを使ってidempotentにcommitを
完遂する。ただし回復時は各pathとtransaction slotをbefore／afterのidentity、size、SHAに分類し、after一致ならstep完了、before一致なら
未完stepとしてno-replace／swapで継続する。どちらにも一致しないobjectは管理外writeとして`unknown`に分類し、そのobjectをafter又は
rollback bytesで上書きせず、全materialをpinしたまま`EXTERNAL_CONFLICT_DURING_COMMIT`と`recovery_required`へ進む。
外部writeがafter SHAと同じbytesへ戻した場合や最終照合後に到着した場合まで識別できるとは主張しない。rollback自体がbefore状態を
復元できない時も`CHANGE_SET_RECOVERY_REQUIRED`とし、一部成功を通常errorへ丸めない。

明示`delete`では原本と別のinternal backupを予約namespaceにpinする。Trash移送前にtransaction ID／change IDから決定した一意名、
candidate path、device/inode、SHA、対象volumeのTrash root identityを`trash_intent`としてfsyncし、candidateだけをmacOS Trashへ移す。
syscall成功直後、返却pathのreceipt保存前にcrashしてもinternal backupを削除しない。recoveryはintentのfile identityを同じvolumeの
Trash内で照合し、一件だけ一致すればそのcanonical pathをreceiptへ固定、0件かつcandidateが残れば同じintentで再試行、複数一致又は
identity不明なら`CHANGE_SET_RECOVERY_REQUIRED`にする。SHAや名前だけで任意のTrash itemを採用しない。

全deleteのTrash path、identity、SHAを含むreceiptをfsyncして`trash_committed`となるまでinternal backupをpinする。Trash移送を
完了できなければtransactionをfinalizeせず、recoveryで再試行する。write／renameの内部backupもruntime commit、diff finalization、
terminal response保存まで保持し、その後だけ削除できる。これによりTrash syscallとreceiptの間のcrashでも、決定的mappingと少なくとも
一つのrecoverable copyを失わない。deleteが0件のtransactionも空のTrash receiptをfsyncして同じ`trash_committed`遷移を通る。

AIShell起動時及び同rootの次のsnapshot／mutation前に未完transactionを走査する。`commit_decided`がなければbefore状態へrollbackし、
存在すればafter状態とruntime journal commitを完遂する。回復完了まで同rootのmutationとfresh snapshotを拒否し、
`CHANGE_SET_RECOVERY_REQUIRED`とtransaction ID、state、損なわず保持したpath、必要な次操作を返す。壊れたjournalを削除、
失敗stepを成功扱い、現在treeから意図を再構成するfallbackは禁止する。

### 5. atomicityの範囲

`all-or-nothing`は、成功responseが返る時点及び正常なrollback／crash recovery後に、対象path集合が全before又は全after状態であり、
混合した安定状態を成功として公開しないことを意味する。同じroot actorを通る`workspace_snapshot`、`workspace_wait`、
`apply_change_set`、AIShell file primitiveはtransaction中の中間状態を読まず、before又はruntime commit後のafterだけを返す。

macOS filesystemは複数の独立pathを一命令で切り替えるtransactionを提供しないため、別process、別API、FSEvents observerへ各rename間の
短い中間状態が見えないとは保証しない。filesystem全体への同時可視性、管理外processとのserializable isolation、悪意ある競合の
封じ込めは主張しない。この制約を隠して`atomic=true`とだけ表示せず、成功resultへ
`visibility: "aishell_serialized_recoverable"`を返す。より強い隔離が必要なcallerは専用worktree又は停止済みconsumerを使う。

### 6. workspace runtimeへのknown mutation commit

filesystem graphの照合後、root actorはtransaction manifestから確定したcreate、modify、delete、renameをADR 0004／0016と同じ
immutable delta journalへ一度だけappendする。recordはtransaction ID、change ID、旧新path、旧新identity、metadata、旧新SHAを持つ。
directory全体を再scanせず、commit時に実測したstat／SHAをworkspace entry indexとcheckpoint write-behindへ反映する。

runtime commitはtransaction IDを内部idempotency keyとし、同じtransactionのrecovery又はFSEvents echoでsequenceを二重に進めない。
後着FSEventsはidentity／SHA照合してsemantic no-opとして吸収する。外部変更が混在していた場合はknown mutationへ混ぜず、通常の
別deltaとして後続sequenceへ記録する。journal appendとentry更新を同じactor transitionで確定し、durable receiptを保存してから
`runtime_committed`と新cursorを発行する。

filesystem commit後にruntime commitが失敗しても成功responseを返さない。recoveryはfinal graphとreceiptを照合し、同じtransaction IDで
journal appendを完遂する。cursorを現在headへ付け替えるだけ、deltaを省略する、full scanを成功経路へsilent fallbackすることは禁止する。

本ADRはADR 0006のcheckpoint schemaへv2を追加し、`committed_transactions`へtransaction ID、root generation、first/last sequence、canonical delta
digestを保持する。marker、更新後entries、journal events、journal sequenceは一つのcheckpoint payloadとして同じatomic saveと
`payload_sha256`に含める。runtime commitのorderingは次だけを許す。

1. root actor上でknown mutation delta、entries、dedupe markerを同時に作る。
2. それらを含むcheckpoint v2を別fileへencode、fsync、atomic replaceし、directoryをfsyncする。
3. checkpoint payload SHA、marker、delta digest、sequence範囲をtransaction receiptへ記録してfsyncする。
4. memory stateを公開して`runtime_committed`と新cursorを返す。

crash recoveryでcheckpoint markerがありtransaction receiptだけがなければ、payload SHAとdelta digestの完全一致を確認してreceiptだけを
補完し、deltaを再appendしない。両方なければtransaction manifestから同じdeltaを作りcheckpoint saveから再実行する。receiptがあるのに
checkpoint markerがない、又はID一致でdigest／sequenceが違う場合は`CHANGE_SET_STORE_CORRUPT`で停止し、cursor付替えや再appendで
修復しない。active transaction、そのdedupe marker、対応checkpointはpinし、transaction／replay slotのretention終了時にだけ
同じatomic checkpoint updateでmarkerをretireできる。checkpoint v1は過去transaction markerを推測できないため、active transaction 0件を
確認して明示full snapshotからv2を作り、v1 entriesを暗黙移植しない。

### 7. result、EvidenceStore、完全diff evidence

成功resultは少なくとも次を返す。

- `transaction_id`、内部追跡用`client_id`、`client_epoch`、`request_sequence`、`status: committed`、`visibility`、`root`、
  内部`from_cursor`／更新後`cursor`、公開`workspace_from_cursor`／更新後`workspace_cursor`。
- request順の`changes`。各itemはchange ID、kind、旧新path、旧新identity、旧新SHA、size、metadata、適用結果を持つ。
- `summary`としてcreate／write／delete／rename件数と総before／after bytes。
- budget内の`diff_preview`、`returned_diff_bytes`、`omitted_diff_bytes`、`has_more`。
- immutableな完全diff artifactの`handle`、`sha256`、`size_bytes`、`expires_at`。
- deleteごとのrecoverable Trash path。

完全diff artifactはtransaction manifest digest、from/to cursor、全changeを含むcanonical JSON headerと、path byte orderで並べた全差分を持つ。
UTF-8 regular fileは改行を含むraw bytesを基準にしたunified diff、binaryは旧新size／SHAと変更kindを記録し、binary bytesをtextへ
誤変換しない。renameは旧新pathを必ず記録し、同内容renameを空diffとして消さない。create／delete、末尾改行差、空fileも表現する。
通常resultのpreviewだけを切り詰め、artifactは全changeを省略なく保持する。

Section 1のexact quota計算と`reserved_unadmitted` allocationはrequest envelopeに加え、rollback、after stage、transaction journal、
Trash backup、完全diff、terminal replay slotの実byte数とoverheadを含む。同じreservation IDの割当領域は
active／recovery_required transactionの間pinし、TTL、LRU、他artifact admissionを理由にevictしない。確保不能ならadmissionも
filesystem変更も行わず`EVIDENCE_QUOTA_EXCEEDED`で停止する。

完全diff artifactはfilesystem切替前に予約quota内で生成し、runtime commit前にfsync・SHA検証する。新cursor、Trash receipt、
terminal stateを含むresult envelopeは各commit後に作るため、prepare時はその最大overheadだけを予約し、未確定値を捏造しない。
生成不能、quota不足、retention中の欠損は`EVIDENCE_QUOTA_EXCEEDED`／`EVIDENCE_CORRUPT`であり、diffなしのcommit成功を返さない。
成功finalizationではstaged diffを既存EvidenceStoreのimmutable artifactへ同じhandle／SHAで昇格し、terminal response bytesと
client replay slotをfsyncする。`finalized_at`はこのdurable化直後かつ初回response直前に一度だけ固定し、artifactとterminal
resultのretentionは`finalized_at + retention_seconds`から開始する。retryでexpiryを延長又は再生成しない。artifactは既存
`artifact_read`でlosslessに取得でき、previewの全page相当bytesとartifact bytesが一致する。保持期限前に削除しない。

失敗resultはtransaction IDを発行済みなら必ず返し、`changed_paths`、`rollback_state`、`recovery_state`、証拠handle、次操作を含める。
`rolled_back`を`committed`と表示せず、`recovery_required`を通常の`CONTENT_CHANGED`へ縮退させない。
`aborted_before_side_effect`はclient ID／epoch／sequence、typed cause、`changed_paths=[]`、`transaction_cursor_advanced=false`、
reservation quarantine／release stateを持つterminal resultとし、同sequence retryへ同じresponseを返す。

### 8. 責務、互換性、benchmark

`ApplyChangeSetService`を`AIShellCore`へ置き、path graph、preflight、transaction store、staging、recovery、diff artifact、
workspace known mutation commitを所有させる。`AIShellMCP`はschema変換だけを担い、MCP handlerから既存file primitiveを順次呼び出さない。
単項目changeも同じtransaction pathを使い、複数項目だけ別実装にしない。

`apply_change_set`はGit index、commit、branch、worktree、formatter、testを変更又は実行しない。patch hunkの曖昧適用、context探索、
three-way mergeを行わず、callerが送った完全after bytesと明示preconditionだけを適用する。競合時に部分適用、別path探索、最新SHAへの
自動置換をしない。

既存`files_write_text`等はfull profileの互換primitiveとして維持する。ただし同じroot actorとrecovery gateを通し、active transactionの
中間状態へ割り込まない。legacy operation成功後もknown mutationとしてworkspace runtimeへ反映するが、複数呼出しを一transactionへ
見せかけない。default／full profileは計画どおり最大9／29 toolであり、本契約のために細粒度transaction toolを追加しない。

既に凍結済みのbenchmark schema／fixture／result v1は履歴比較の正本として不変に保ち、`apply_change_set`結果や新指標を後付けしない。
transaction統合比較はbenchmark v2を新設し、同じtask fixtureについてsuccess、全試行token、tool call、wall timeに加え、rollback、
recovery、diff artifact read、filesystem entries rescanned、bytes reread、idempotent retryを別fieldで記録する。v1とv2の数値を同じ母集団と
見せたり、v2不足fieldをv1から推測補完したりしない。

## Verification contract

ACE-051はproductionと同じtransaction storeとfailure injection seamを使い、少なくとも次を固定する。

- create、write、delete、rename及び3件以上の混合changeで、全expected SHA／absence一致時だけ全after状態、新cursor、完全diffを返す。
- 一件目／中間／最終pathのstale SHA、expected absence違反、cursor head遅延、別root、別volume、symlink/root escape、directory、
  case-fold衝突、同一identity二重指定で変更0件になる。
- rename chain／cycleを正しく適用し、source又はdestination重複、自己rename、曖昧な上書きを`CHANGE_SET_CONFLICT`にする。
- pin済みroot／parent FDをpath rename、symlink差替え、case-only renameと競合させ、`openat`／`*at`が元identityだけを操作する。
  `RENAME_EXCL`／`RENAME_SWAP` capability不足では変更0件になり、path-based overwriteへfallbackしない。
- 予約`.aishell-transactions`が全read／search／Git context／delta／変更targetから除外される。利用者所有の同名path、marker改ざん、
  root identity不一致、未知version、migration中crashをfail closedにし、旧exclusion cursorとcheckpointを新generationへ付け替えない。
- prepareの各write/fsync、`commit_decided`の前後、各退避／配置rename、directory fsync、diff finalize、runtime journal append、
  Trash移送へ一件ずつ障害を注入する。再起動後に全before又は全afterへ収束し、安定したpartial state 0件、証拠欠落0件にする。
- commit中の管理外FD write／renameをbarrierで競合させ、観測時にbefore、after、unknownを正しく分類する。unknownを上書きせず
  `EXTERNAL_CONFLICT_DURING_COMMIT`と`recovery_required`を保持し、最終照合後のwriteを封じられるという過大なtest期待を置かない。
  管理外readerに中間pathが見えるfixtureでもglobal atomicityを期待しない。
- rollback material改ざん、journal truncation／digest不一致、after stage SHA不一致、transaction ID重複をfail closedにし、
  storeを削除又は現在treeから再構成しない。
- 同じtransactionのrecoveryとFSEvents echoを重ねてもdeltaが一回だけで、全changeを追加scanなしにentry indexへ反映し、
  from cursorから新cursorまでをworkspace deltaで再生できる。
- checkpoint save前後とtransaction receipt fsync前後でcrashさせ、markerなし／markerのみ／両方の各状態がSection 6のorderingどおり
  一回だけcommitされる。receiptのみ、marker digest不一致、sequence不一致は再appendせずcorruptionになる。
- Trash syscall成功直後からreceipt fsyncまでの各点でcrashさせ、candidate identityから同じTrash itemへ回復し、internal backupが
  receipt durable前に消えない。0件、複数件、identity不一致は別itemを採用せずrecovery requiredになる。
- UTF-8、binary、空file、末尾改行差、permission／ACL／xattr保持、同内容rename、64 MiB上限、上限+1を固定する。
- diff previewのbudget N/N+1、完全artifactのsize／SHA／全path、retention、corruption、quota failureを検証し、preview省略時も
  artifactに全差分がある。
- quota reservation保存前後、EvidenceStore昇格、terminal response保存へ障害を注入し、active transactionのreservation／artifact／
  backupがevictされない。retentionは一度だけ固定した`finalized_at`から始まり、retryで延長されない。
- client ID UUID v4のcanonical form、epoch／sequence 1／2、最大JSON integer、gap、nonterminal predecessorを境界値で固定する。
  同じclient／epoch／sequenceのresponse喪失、cancel、再起動後retryはprocess中／terminalの同じtransactionへ合流し、同digestは同result、
  異なるdigestは`CHANGE_SET_SEQUENCE_CONFLICT`になる。未登録client、旧epoch、未来epochをそれぞれ
  `CHANGE_SET_CLIENT_NOT_REGISTERED`、`CHANGE_SET_EXPIRED`、`CHANGE_SET_CLIENT_EPOCH_AHEAD`へ分離し、retire済みfree slotの同epochも
  個別recordなしでexpiredにする。
- high-water 255／256／257件でreplay ringと`replay_floor`を検証する。window以前は個別recordが実在しないまま
  `CHANGE_SET_EXPIRED`、window内record欠損はstore corruption、artifact retention終了後は再適用なしのexpiredになる。
- client process再起動は同じID／epoch／in-flight sequenceを使い、client state resetはowner承認rotation後に同じID＋新epoch＋sequence 1を
  使う。rotation前のringを全消去しても旧epoch requestはcurrent epochだけからexpiredとなり、旧epoch request tombstoneが0件である。
- allocate 64件／65件、terminal slot retire、同じ固定slot／stable client IDの再allocateとepoch増加、同じclient IDのrotationを固定する。
  満杯時もretire→allocateでslot数64のまま回復し、client ID差替え、active slot自動evict、単なる上限増加、TTLによるhigh-water evictionを許さない。
- owner proofのroot／action／client／epoch／expiry改ざん、期限切れ、再利用を拒否する。nonterminal transaction中のrotation／retireは
  `CLIENT_ROTATION_BLOCKED`／`CLIENT_RETIRE_BLOCKED`となり、recovery後だけ進める。最大epoch slotは再利用せず他のretire可能slotへ誘導する。
- registry reinitializeはactive slot又はnonterminal transactionが一件でもあれば拒否し、全retire後だけgeneration、全64 stable ID、
  epoch 0を一回で切り替える。crash／response喪失後も同control receiptを返し、旧client requestを新slotへ対応付けない。
- apply admission対rotation、同expected epochのrotation 2件、rotation対retireをbarrierで競合させ、registry actorの最初のlinearizationだけが
  成功する。後続はexpired／blocked／`CLIENT_EPOCH_CHANGED`の契約どおりで、epochとsequenceを混在させない。
- free slotが一件だけの同時allocate 2件、retire対allocate、retire済みclientのstale apply対再allocateを競合させ、slot重複割当、
  client ID差替え、旧epoch admissionが0件である。
- allocate／rotation／retireについてregistry atomic replace前後とresponse前でcrashさせる。replace前は同proof retry、replace後は同じ
  control request IDのreceipt replayとなり、slot消失、epochだけの前進、proof二重使用がない。control receipt 128／129件では
  unexpired receiptをevictせず、expiry後にcapacityが回復する。
- validation各段、quota reservation前、`reserved_unadmitted`保存後、atomic admission fsync前後、最初のtransaction directory作成前後で
  crashさせる。admission前はhigh-water不変かつworkspace／namespace副作用0件でorphan reservationを解放し、admission後は同じ
  slot／transactionだけをrecoveryして二重適用しない。
- UTF-8／base64 content、空bytes、64 MiB、複数changeをcanonical reservationへencodeし、header/content length、descriptor offset、
  per-content SHA、framed request digestを独立再計算する。reservationをdecryptして元requestの全after bytesをclient入力なしに再構成できる。
- reservation header、ciphertext、AEAD tag、length、root/client/epoch/sequence binding、descriptor range、request digestを一fieldずつ改ざんし、
  `CHANGE_SET_RESERVATION_CORRUPT`でtarget変更0件又はrecovery requiredになる。caller retry、workspace、diffから補完しない。
- Keychain unavailable／wrong key、owner-only permission違反、secretを含むcontent fixtureでreservation/admission境界を確認し、plaintext、key、
  content fragmentがlog、activity、MCP error、public artifactへ0 byteである。
- step 2 payload fsync後／step 3 admission fsync後／step 4 materialization前でserverとclient stateを同時に失わせる。unadmittedは安全にreleaseし、
  admittedはserver単独で同じtransactionをmaterializeしてterminalへ進み、client retry待ちのnonterminalを残さない。
- orphan cleanupはlive lease、同boot 10分、old boot startup、admissionあり、transaction directoryあり、registry unreadableを分離する。
  後三者を削除せず、active／recovery reservationがTTL／LRU／quota pressureでevictされない。
- admission後のcursor進行、expected SHA変更、root置換、capability失効、quota binding不一致をtarget mutation前に注入し、
  `aborted_before_side_effect`、変更0件、terminal replayへ収束する。同じ障害をtarget receipt後／commit_decided後に注入した場合はabortせず
  recoveryへ進む。
- reservation key喪失又はcorruptionでclient stateも失ったfixtureは、target receipt 0件ならowner proof付き`abort_pre_side_effect`でterminal、
  replay slot、quota releaseへ収束する。receiptあり、phase digest不一致、namespace不明ではowner abortを拒否しpartial stateを隠さない。
- terminal種別ごとにencrypted material retentionを確認し、通常terminalはregistry save後release、corruption quarantineは24時間、
  recovery requiredは期限なしpinとなる。quarantine後もplaintextを保存しない。
- server crash後の初回snapshot／mutationがrecovery完了前にfresh成功せず、回復後は同じtransaction ID、after state、cursor、
  diff artifactを返す。回復不能なら具体的pathと次操作を持つ`CHANGE_SET_RECOVERY_REQUIRED`になる。
- 既存file primitive、workspace snapshot/wait、default 9／full 29 tool catalogを非回帰にする。
- 凍結benchmark v1のfixture、schema、digest、既存resultがbyte-for-byte不変で、統合benchmark v2だけがtransaction、recovery、
  EvidenceStore、idempotent retryの新指標を持つ。

docsだけを固定するACE-050ではSwift testを実行せず、Markdown構造、ADR 0004／0006／0016、現行file primitive、
development planとの整合、git diffをfocused verificationとする。ACE-051／052では上記focused suiteに加え、MCP initialize、
tools/list、成功・precondition失敗・rollback・recovery・diff artifactのwire fixtureを確認する。

## Consequences

AI hostは複数fileの確認、個別更新、手動rollback、再snapshotを一往復へまとめられ、AIShellは変更後cursorと完全diffを直接返せる。
その代わり、単一file writeより多いdisk space、fsync、transaction journal、起動時recoveryが必要になる。性能のためにrollback material、
diff evidence、cursor照合のいずれかを省略せず、Phase 5 benchmarkで成功課題あたりのtoken、tool call、wall timeへの効果を測る。

本契約のall-or-nothingはdurable recoveryとAIShell内のserialized visibilityを保証する。filesystem-wide simultaneous visibilityは
保証しないが、これを理由に複数changeを直列primitiveへ退行させない。将来OSが強いtransaction primitiveを提供する場合も、
公開schema、expected state、evidence、runtime commitの契約を維持したまま内部commit方式だけを置換する。
