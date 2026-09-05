# ADR 0006: 永続workspace checkpoint契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: accepted
- Date: 2026-07-21
- Control: `aishell-capability-expansion-20260721`
- Lattice task: `ACE-010`

## Decision

永続checkpointは再起動後の再読を減らすための照合開始点であり、現在のfilesystem状態の正本ではない。
復元時は必ずroot identity、checkpoint schema、exclusion規則、FSEvents event IDの連続性、現在のentry metadataを
照合する。連続性を証明できないcheckpointを黙って採用したり、黙ってfull scanへfallbackしたりしない。

checkpointは`RuntimeStore.baseDirectory/workspaces/<root_digest>/checkpoint.json`へ置く。`root_digest`はADR 0004と
同じcanonical root path、device、inodeのSHA-256であり、directory名だけをidentity根拠にしない。書込みは同じ
directoryの一時fileへ完全encode・fsync後、atomic replaceする。旧checkpointは置換成功まで維持し、partial fileを
有効状態として公開しない。

## Schema v1

top-level schema identifierは`aishell.workspace-checkpoint.v1`とし、次を必須にする。

| Field | 契約 |
|---|---|
| `root_path` | 保存時のcanonical absolute path。許可root照合とdiagnostic用 |
| `root_identity` | `device:inode`。現在値との不一致はroot置換 |
| `root_digest` | pathとidentityの束縛。directory選択値との一致を検証 |
| `exclusion_digest` | scan除外規則version。不一致なら旧entryを利用しない |
| `event_store_uuid` | root deviceのFSEvents系列UUID。取得不能は`null`でwarm restore不可 |
| `generation` | 同じ連続観測系列のUUID。受理したwarm restoreでは維持 |
| `last_event_id` | observer開始境界又は同期drainで実際に処理した最後のFSEvents event ID。未取得は`null` |
| `journal_sequence` | checkpointへ反映済みのjournal sequence圧縮点 |
| `journal_events` | 圧縮点より後の未適用event。通常の確定checkpointでは空配列 |
| `entries` | relative pathをkeyとする決定的path順のentry集合 |
| `created_at` / `last_accessed_at` | ISO 8601 UTC。quotaのLRU判断だけに使い、freshness根拠にしない |
| `payload_sha256` | 自fieldを除くcanonical JSON bytesのSHA-256 |

各entryは`path`、`identity`（device/inode）、`kind`（file/directory）、`size_bytes`、nanosecond精度の
`modified_at`、`sha256`、`hash_state`を持つ。通常fileはcontent SHA-256を保持する。directoryは
`hash_state=not_applicable`、読取り不能又は明示hash budget外のfileは`sha256=null`かつ
`hash_state=deferred`にし、hash済みに見せない。symlinkとroot外へ解決されるentryは保存対象にしない。

checkpointは公開`workspace_snapshot`のentry budgetで切り詰めない。全indexを保存し、書込み順・JSON key順を
決定的にする。公開結果の省略と内部indexの欠落を混同しない。

## Restore and event continuity

warm restoreは次の順で行う。

1. 許可rootと現在のroot identityを確認する。
2. schema、payload hash、root/exclusion bindingを検証する。
3. observerをcheckpointの`last_event_id`以後から開始し、callbackはeventを同期bufferへ保持する。
4. 現在のdirectory treeをmetadata照合し、create/delete/identity/size/mtime差分とreplayed event対象だけをcontent再読する。
5. replay完了後にもう一度observerを同期drainし、観測中の変更を照合してからfresh resultを返す。

observerはroot deviceの`FSEventStreamCreateRelativeToDevice`で作り、checkpointのFSEvents UUIDとevent IDを同じvolume系列へ
束縛する。初回作成直前の`FSEventsGetLastEventIdForDeviceBeforeTime`をconservativeな開始境界とし、その後は同期drainで実際に
取り込んだper-device callback IDだけへwatermarkを進める。flush後のglobal current IDを処理済みに見せてはならない。
device timestamp boundaryは直後のcallback latest IDより6秒以上遅れる実測があるため、復元時のrollback判定には流用しない。
これによりcallbackとactor処理の競合で
未処理eventを飛び越えず、「eventが無かった」のか「event IDを取得していない」のかを区別する。`last_event_id=null`を
連続性証明として扱わない。UUID不一致・取得不能はwarm restoreへ使わず、復元時の保存IDが現在のsystem event IDより大きい
場合もevent databaseの巻戻りとして`RESCAN_REQUIRED`にする。

同じsize/mtimeへ戻されたoffline変更もevent replay対象ならcontentを再読する。event IDが`null`、履歴期限切れ、
wrap/drop/root-change flag、又は開始時点の連続性を証明できない場合は`RESCAN_REQUIRED`と理由を返す。
callerが明示full snapshotを要求した時だけ全entryを再走査・必要なcontentを再hashし、新generationを発行する。
復元中にgap/dropを検出した明示fullは旧entryを全廃して再構築する。再構築中の同期drainでもgap/dropを検出した場合は
fresh結果を返さず`RESCAN_REQUIRED`で止める。

受理したwarm restoreはcheckpointのgenerationを維持し、journal sequenceはcheckpoint確定点から継続する。
checkpoint確定時点までのpath eventは現在entryへ適用済みなので圧縮し、`journal_events`を空にする。この圧縮点と同じ
sequenceのcursorは再起動直後から直接継続できる。圧縮点より古いcursorは変更履歴を現在entryから捏造せず
`CURSOR_EXPIRED`にする。
root identity、exclusion規則、又は互換不能schemaの変更後は旧generationのcursorを`CURSOR_EXPIRED`で拒否する。
checkpoint採用前に発行済みのcursorを別generationへ付け替えない。

## Migration and corruption

schema migrationはversionごとの純粋な明示migratorだけを許可する。migratorは入力payload hash検証後に新fileを
別名で生成し、新schemaの全invariantを検証してからatomic replaceする。field欠落を推測値で埋めるmigration、
未知のmajor versionの部分読込み、decode失敗の握りつぶしは禁止する。

corrupt、unsupported、migration失敗はそれぞれ`CHECKPOINT_CORRUPT`、`CHECKPOINT_UNSUPPORTED`、
`CHECKPOINT_MIGRATION_FAILED`としてpathと原因を返す。自動削除しない。callerが明示full snapshotで再構築を選ぶまで、
壊れたcheckpointの存在と原因を保持する。

## Quota and retention

既定quotaは同時保持8 root、1 rootあたり最大500,000 entry又は128 MiB、全checkpoint合計512 MiBとする。
quota値は内部versioned policyに束縛し、変更をschema外の暗黙挙動にしない。

- 保存前にencode後の実byte数とentry数をpreflightする。単一root上限超過は
  `CHECKPOINT_QUOTA_EXCEEDED`を返し、直前の有効checkpointを置換しない。
- 合計quota超過時だけ、activeでないrootを`last_accessed_at`の古い順に完全directory単位でevictできる。
  対象directoryは同一volumeのstagingへ移動し、新checkpointのatomic commitが失敗した場合は元へ戻す。commit成功後だけ
  stagingを削除し、eviction対象と理由をactivityへ記録する。
- evict済みrootの次回利用は`checkpoint_state=missing`として明示する。warm restore成功に見せず、callerが明示full
  snapshotを選ぶ。active root、処理中transaction、最新の有効checkpointを部分削除しない。
- 日数だけを理由に有効checkpointを失効させない。freshnessは時刻でなくOS identityとevent continuityで判定する。

大規模workspaceを小さいindexへsilent truncationして対応しない。quotaを増やすか、明示full snapshotでcheckpointを
使わず処理するかはcallerの選択であり、製品側が成功扱いで能力を縮小しない。

## Compatibility and verification consequences

既存`workspace_snapshot` v1のfull/delta、entry/context budget、Git status、typed cursor errorは維持する。
永続化はv2の追加能力であり、公開budgetやlegacy primitiveを削除する理由にしない。

ACE-011はcold start、warm restore、offline create/modify/delete/rename、同size/mtime変更、event gap、root置換、
corrupt/unsupported/migration失敗、quota preflight、atomic replace失敗を先行testで固定する。ACE-012はその安全網を
変更せずcheckpoint storeとobservation journalをruntimeへ統合する。
