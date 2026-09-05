# ADR 0008: Git diff context契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: accepted
- Date: 2026-07-21
- Lattice task: `ACE-020`
- Control: `aishell-capability-expansion-20260721`

## Context

現行`workspace_snapshot`は`git status --short`を最大500行返すだけで、staged、unstaged、untracked、
明示baseとの差分を同じpathで区別できない。renameの旧path、blob SHA、完全証拠、budget超過後のcontinuationも
持たないため、AI hostは追加のGit呼出しと再読を必要とする。Phase 2ではGitをAIShellが直接起動するworkerとして
利用し、filesystemを所有するworkspace runtimeの同一観測点へdiff evidenceを束縛する。

## Decision

### 1. 公開境界

`workspace_snapshot`へ省略可能な`git_diff` requestを追加し、resultへ省略可能な
`gitDiff: aishell.git-diff-context.v1`を返す。既存の`gitStatusState`／`gitStatus`は互換期間中も維持し、
`gitDiff`から再構成できるという理由でPhase 2中に削除しない。

requestは次の値を持つ。

- `mode`: `worktree | branch`。省略時は`base_ref`なしならworktree、ありならbranch。branchは`base_ref`必須。
- `base_ref`: 比較元commit-ish。省略時は観測開始時の`HEAD`。入力文字列と解決commit SHAを両方保持する。
- `byte_budget`: 全summary／patch previewで共有する1〜1,048,576 bytes。既定65,536。
- `continuation`: 直前resultが返したopaque token。初回requestの他fieldと同時指定しない。
- `include_patch`: 既定true。falseでもchange inventory、SHA、完全証拠handleは生成する。

repositoryでないrootに明示`git_diff` requestを行った場合は`NOT_GIT_REPOSITORY`とする。requestを省略した
従来snapshotは`gitStatusState: not_repository`を維持する。

Phase 6のworktree/branch比較では、budget対象のchange/patchとは別に`comparisonMode`、
`repositoryIdentity`、`headBranch`、`headSHA`、`baseRef`、`baseSHA`、`dirtyState: clean | dirty`を常に返す。
これらをdiff本文の省略に巻き込まず、AI hostがどのroot・branch・base・dirty状態を比較したかを先に判定できるようにする。
detached HEADは`headBranch=null`とし、branch名を推測しない。

unborn repositoryで`base_ref`を省略した場合、resultは`baseRef=null`、`baseSHA=null`、`headSHA=null`とし、
`base_to_head`は0件、`staged`だけをempty treeからindexまで比較する。explicit `base_ref`を指定したunborn repositoryは
比較先HEADが存在しないため`UNBORN_HEAD_WITH_EXPLICIT_BASE`で停止する。empty treeをHEAD commitへ偽装しない。

凍結済みbenchmark v1は過去baseline証拠としてbyte不変に保つ。Phase 2〜5のF契約を統合した
`representative-execution-contracts.v2`では`workspace_snapshot`の`snapshot-git` templateを
`action`、`path`、`git_diff: { base_ref, byte_budget, include_patch }`へcutoverし、旧`git_mode: porcelain-v2`を
送らない。v2 materializer、observer projection、freeze evidenceを同じtransactionで発行し、fixture専用の
別request形式を公開契約へ持ち込まない。

`path`は許可root内の任意directoryを受ける。Git repository rootは`git rev-parse --show-toplevel`で上方探索する。
repository rootとcommon Git directoryの各実体は、`AllowedPathResolver`が同じconfigured rootから導出した
effective allowed-root familyのいずれかに含まれ、linked worktreeとcommon directoryが相互登録済みでなければならない。
family外なら`REPOSITORY_OUTSIDE_ALLOWED_ROOT`で停止する。repository rootが`path`より上位なら、Git workerへ
literal pathspecを渡してchange、patch、untrackedを`path`配下だけへ限定する。repository全体を暗黙に返さない。

### 2. 観測点と差分layer

一回のrequestはGit lockを作らない`--no-optional-locks` worker群で、次を同じ観測transactionへ集める。

1. `base_to_head`: resolved base commitから観測開始時HEADまでのcommitted差分。
2. `staged`: 観測開始時HEAD（unborn時はempty tree）からindexまで。
3. `unstaged`: indexからworktreeまで。
4. `untracked`: indexに存在しないworktree file。

同じpathが複数layerに存在しても統合しない。各`GitDiffChange`は`layer`、`kind`、`path`、
`previousPath`、`objectFormat`、`oldObjectID`、`newObjectID`、`oldObjectIDSource`、`newObjectIDSource`、
`isBinary`、`modeBefore`、`modeAfter`を持つ。`kind`は
`added | modified | deleted | renamed | copied | type_changed | unmerged`のclosed setとする。unmergedは
存在するstage 1/2/3だけを`stageEntries`へ保持し、index treeを作れない場合は`indexTreeSHA=null`と
`indexState: unmerged`を返す。rename/copy検出は`--find-renames=50% --find-copies=50% --find-copies-harder`
を全layerで固定し、scoreを`similarityPercent`として返す。renameをdelete＋addへ黙って劣化させない。

untracked fileは`oldObjectID=null`、content SHA-256を`contentSHA256`へ持つ。Git object IDとSHA-256を
混同せず、field名とalgorithmを明示する。submoduleはfile本文へ展開せずgitlink modeとcommit SHAを返す。
UTF-8へlossless変換できないpathは置換文字で丸めず`PATH_ENCODING_UNSUPPORTED`で停止する。

object IDの意味はlayerごとに固定する。`objectFormat`は`git rev-parse --show-object-format`の
`sha1 | sha256`であり、zero OIDを公開resultへ出さない。

| layer / kind | `oldObjectID` | `newObjectID` |
| --- | --- | --- |
| `base_to_head` | base treeのobject ID。addedは`null` | HEAD treeのobject ID。deletedは`null` |
| `staged` | HEAD treeのobject ID。unborn／addedは`null` | index stage 0のobject ID。deletedは`null` |
| `unstaged` | index stage 0のobject ID。addedは`null` | worktree raw bytesを`git hash-object --no-filters --stdin`で算出したraw blob object ID。deletedは`null` |
| `untracked` | `null` | worktree raw bytesから同じ方法で算出したraw blob object ID |
| `unmerged` | `null`。`stageEntries`へ存在するstageだけを保持 | `null`。解消後を推測しない |
| submodule | 比較元gitlink commit ID。存在しなければ`null` | 比較先gitlink commit ID。存在しなければ`null` |

`hash-object`にはfile pathをoperandとして渡さず、AIShellが許可root内で開いた完全bytesをstdinへ渡す。
`--no-filters`を必須にし、`.gitattributes`、clean/process filter、EOL変換、外部processを一切起動しない。
このOIDは将来indexへ入る正規化済みOIDではなく、観測したraw bytesのGit blob identityであるため、各endpointへ
`oldObjectIDSource`／`newObjectIDSource: tree | index | worktree_raw | untracked_raw | gitlink | none`を返す。
null endpointのsourceは`none`である。

symlinkは参照先をopenせず、`lstat`で型を確定して`readlink`相当のlink target bytesを取得し、そのbytesを
`git hash-object --no-filters --stdin`へ渡す。symlinkであるendpointのmodeだけを`120000`とし、addedのbeforeと
deletedのafterはnull、type changeは各endpointの実modeを返す。artifactにもlink bytesのSHA-256を保存する。
symlinkの参照先内容やroot外pathは読まない。

Git workerは`LC_ALL=C`、`GIT_OPTIONAL_LOCKS=0`、`GIT_LITERAL_PATHSPECS=1`を固定し、`--no-ext-diff`、`--no-textconv`、
`--submodule=short`を使う。refは`git rev-parse --verify --end-of-options <ref>^{commit}`で先にobject IDへ解決し、
差分commandには解決済みobject IDだけを渡す。pathspecの前には`--`を置き、refやpathをoptionとして解釈させない。

### 3. identity、完全証拠、budget

resultは少なくとも次を返す。

- `repositoryRoot`、repository root identity、`headSHA`（unbornはnull）、`baseRef`、`baseSHA`
- index tree SHA、workspace cursor、観測開始／終了時のGit state digest
- layer別change件数、順序付き`changes`、budget内の`patches`
- `returnedBytes`、`omittedBytes`、`hasMore`、`continuation`
- raw `--raw -z`／patch evidenceを保持する`expires_at`付きartifact handleと、完全bytesのSHA-256

change順は`layer → path byte order → previousPath byte order → kind`で決定的にする。budget対象は、各change metadataを
RFC 8785 JSON Canonicalization Scheme（JCS）でencodeした`change` itemと、対応previewをJCSでencodeした`patch` itemの
各末尾へ単一LF byte（`0x0a`）を付けて順に連結したUTF-8 JSONL item streamだけとする。JCSが定めるkey順、string escape、
number表現を使い、末尾LFもbyte数へ含める。envelope、identity、集計、artifact descriptor、continuation tokenはbudget対象外である。
一つのitemは分割しない。次itemが収まらない場合は0件でもcontinuationを返し、silent truncationしない。
`returnedBytes`は返したitem bytes、`omittedBytes`は同一snapshotに残るitem bytesの総和として独立再計算可能にする。
完全証拠はartifact retention中に削除しない。

完全証拠artifactは次のversioned framingへ固定する。先頭はASCII `AISHELL-GIT-DIFF`、NUL、version `0x01`。
各recordは`kind: uint8`、`headerLength: uint32 big-endian`、JCS header bytes、
`bodyLength: uint64 big-endian`、body bytesの順とする。record kindは
`1=raw_stdout`、`2=patch_stdout`、`3=worker_stderr`、`4=untracked_content_digest`、
`5=symlink_target_digest`、`6=workspace_binding`、`7=unmerged_stages`とする。

全record headerはexact object
`{ "argumentsDigest": string|null, "layer": string|null, "path": string|null,
"recordKind": string, "stream": "stdout"|"stderr"|"none" }`とする。null fieldも省略しない。
`argumentsDigest`はresolved executable URLと順序付きargumentsのexact object
`{ "arguments": [string...], "executable": string }`をJCS encodeしたbytesのSHA-256であり、Git command record以外はnull。
Git commandごとにlayer順`base_to_head, staged, unstaged, untracked`、その中で
`raw_stdout, patch_stdout, worker_stderr`の順に空bodyも含めて記録する。その後、path byte orderで
untracked／symlink digest、最後にworkspace binding、unmerged stagesを各1 record記録する。
artifact SHA-256はheader、長さ、空bodyを含むframing後の全bytesへ掛ける。

header値はkindごとに次へ固定する。

| kind | `argumentsDigest` | `layer` | `path` | `recordKind` | `stream` |
| --- | --- | --- | --- | --- | --- |
| 1 | 対応Git command digest | 対応layer | `null` | `raw_stdout` | `stdout` |
| 2 | Git生成時は対応command digest、AIShell生成のuntracked previewは`null` | 対応layer | `null` | `patch_stdout` | `stdout` |
| 3 | 対応Git command digest | 対応layer | `null` | `worker_stderr` | `stderr` |
| 4 | `null` | `untracked` | canonical path | `untracked_content_digest` | `none` |
| 5 | `null` | `null` | canonical path | `symlink_target_digest` | `none` |
| 6 | `null` | `null` | `null` | `workspace_binding` | `none` |
| 7 | `null` | `null` | `null` | `unmerged_stages` | `none` |

body encodingはkindごとに次へ固定する。

| kind | body bytes |
| --- | --- |
| 1 `raw_stdout` | Git stdoutの完全raw bytes。NULを保持する |
| 2 `patch_stdout` | Git patch stdoutの完全raw bytes。encoding変換しない |
| 3 `worker_stderr` | Git stderrの完全raw bytes。空でもrecordを置く |
| 4 `untracked_content_digest` | exact object `{ "path": string, "sha256": string }`のJCS bytes |
| 5 `symlink_target_digest` | exact object `{ "path": string, "sha256": string }`のJCS bytes |
| 6 `workspace_binding` | exact object `{ "comparisonBinding": object, "evidenceContentDigests": array, "schema": "aishell.git-workspace-evidence.v1" }`のJCS bytes |
| 7 `unmerged_stages` | exact object `{ "mode": string, "objectID": string, "path": string, "stage": 1|2|3 }`の配列をpath byte順→stage昇順にしたJCS bytes。存在するstageだけを列挙する |

kind 4/5と`evidenceContentDigests`はcanonical pathごとに一件だけとし、同じpathが複数layerに現れても重複させない。
同じpathをregular／symlinkの両方として観測した場合はraceなので`CONTENT_CHANGED`とする。
公開changeの`stageEntries`もkind 7と同じexact object配列と欠落stage規則を使い、zero OIDやnull placeholderを入れない。

workspace comparison bindingはexact object
`{ "entries": [...], "eventHighWater": decimal-string|null, "generation": string, "rootIdentity": string,
"schema": "aishell.git-workspace-binding.v1", "workspaceCursor": string }`とする。`entries`はpath UTF-8 byte順で、
各entryをexact object `{ "hashState": "hashed"|"deferred"|"not_applicable", "identity": string,
"kind": "regular"|"directory"|"symlink", "modifiedAtNanoseconds": string|null, "path": string,
"sha256": string|null, "sizeBytes": int64 }`とする。directoryは`not_applicable/null`、4 MiB超等の未読regular fileは
`deferred/null`を保ち、binding作成だけのために全量再読しない。comparison bindingのhash stateはtransaction中に
enrichせず、Git evidence取得時に読んだregular file／symlinkのSHA-256はpath byte順の別exact配列
`evidenceContentDigests: [{ "kind": "regular"|"symlink", "path": string, "sha256": string }]`へ置く。

取得順は、(1) pre comparison binding、HEAD、index state、layer別raw inventory digestを取得、
(2) patchとevidence content bytesを取得、(3) layer別raw inventoryを再取得、
(4) post comparison binding、HEAD、index stateを取得、(5) pre/postのcomparison binding、HEAD、index、raw inventory digestを
完全一致比較、(6) post bindingと`evidenceContentDigests`をartifact kind 6へ封入、の順とする。
raw inventory digestはexact object
`{ "layers": [{ "layer": string, "rawSHA256": string }...], "schema": "aishell.git-raw-inventory.v1",
"untrackedPathsSHA256": string }`のJCS bytesへ掛けるSHA-256である。`layers`は
`base_to_head, staged, unstaged`順、各`rawSHA256`は対応`--raw -z`完全bytesへ掛ける。
`untrackedPathsSHA256`はpath byte順のNUL終端UTF-8 path列（空集合は0 bytes）へ掛ける。不一致ならartifactを公開せず
`CONTENT_CHANGED`で停止する。comparison bindingはruntime保有hash stateのままなので、evidence読取によって
`deferred`から`hashed`へ変化せず、内容不変の大fileを自己不一致にしない。
`worktreeEvidenceDigest`はexact object
`{ "artifactSHA256": string, "bindingDigest": string, "evidenceContentDigest": string,
"schema": "aishell.git-worktree-evidence.v1", "unmergedStagesDigest": string }`をJCS encodeしたbytesのSHA-256とする。
`bindingDigest`はpost comparison binding JCS bytes、`evidenceContentDigest`は上記配列JCS bytes、
`unmergedStagesDigest`はpath／stage番号／mode／object ID順のJCS配列のSHA-256である。continuation時はartifactを再生成せず、
現在のcomparison binding、HEAD、index stateを再取得して保存済みpost bindingと照合する。

continuationはrequest、repository identity、base/head/index state/tree、worktree evidence digest、workspace generation、
次offsetへMAC相当のprocess-local secretで束縛する。改ざんは`INVALID_CONTINUATION`、いずれかの状態変化は
`CONTENT_CHANGED`、retention失効は`CURSOR_EXPIRED`とし、先頭からの暗黙再取得へfallbackしない。

従来`gitStatus`も黙って500件へ切り捨てない。互換fieldは維持したまま`gitStatusReturned`、
`gitStatusOmitted`、`gitStatusHasMore`を常に返す。`git_diff`なしの従来requestでも省略を機械判定可能にし、
完全列挙が必要なら`git_diff`のbudget／continuationを使う。

### 4. raceと失敗

worker群の前後でHEAD、index state/tree、layer別raw inventory digest、workspace comparison bindingを比較する。不一致なら部分結果を返さず
`CONTENT_CHANGED`とする。Git exit、壊れたindex、unresolved base、artifact発行失敗はそれぞれtyped errorで停止し、
`git status`だけの結果、filesystem推測、前回cacheへfallbackしない。Git command文字列をshell評価せず、
executable URL、arguments、working directoryを分離する。

## Verification contract

- frozen representative suiteの`git-diff-context/staged-rename`はrename pathを、`mixed-state`はchanged pathと
  continuation integrityを検証する。このsuiteがlayer、object ID、artifact SHAまで検証すると過大主張しない。
- ACE-023aのcontract-focused fixtureは`staged`の単一rename、旧新path、object ID、完全証拠SHAを一致させる。
  `mixed-state`はunstaged README変更とuntracked sourceを別kind/layerで返し、全page連結が単発完全結果と一致する。
- 同path staged＋unstaged、base-to-head＋staged、delete、binary、type change、submodule、symlink、unborn HEADを固定する。
- page間のworktree／index／HEAD変更、token改ざん、base未解決、`-`始まりbase、Git失敗、invalid UTF-8 pathはtyped errorになる。
- byte budget N/N+1、UTF-8境界、item境界を検証し、canonical JSONLから`returnedBytes`／`omittedBytes`、
  length-prefixed evidenceからartifact SHAを独立再計算する。
- worktree/branch両modeでrepository identity、branch、base SHA、dirty stateがdiff budgetにかかわらず返ることを固定する。
- subdirectory configured root、allowed root外repository、linked worktree、unmerged indexを固定する。
- `*`、`?`、`[`、`:(`を含む実directory名と似た兄弟directoryを用意し、literal pathscope外を返さないことを固定する。
- external clean/process filterとEOL attributeが存在しても起動せず、raw bytes OIDが決定的であることを固定する。
- 既存`workspace_snapshot` cursor、rename/delete、checkpoint、`gitStatusState`／`gitStatus`を非回帰とし、
  500件超で`gitStatusOmitted`が非zeroになることを確認する。

## Consequences

ACE-023はこの契約を`AIShellCore`のdomain serviceへ実装し、MCP handlerには変換だけを置く。
GitはOS状態を補う直接workerであり、状態所有者や公開toolの寄せ集めにはしない。Phase 2で新しい独立公開toolは
追加せず、default 7／full 25 toolを削減しない。
