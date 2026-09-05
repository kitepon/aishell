# ADR 0015: Artifact query／history compare契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: superseded by ADR 0021
- Date: 2026-07-21
- Lattice task: `ACE-042`
- Control: `aishell-capability-expansion-20260721`

> このADRは翌日の[ADR 0021: artifact query・history compare最終契約](0021-artifact-query-final-contract.md)に
> 置き換えられた。ACE-042の完了証拠もADR 0021である。実装契約としては参照しないこと。
> 主な相違: 本ADRは`artifact_read` v2の`action`を`read | search | diagnostics | compare`の4種とした。
> ADR 0021は公開actionを`search | next | compare`へ整理し、run sourceをADR 0014のterminal run indexへ
> 束縛して`project_id`と`store_identity_digest`の一致を必須にし、別project/storeのhandleを
> `ARTIFACT_SCOPE_MISMATCH`、未finalizeのrunを`RUN_NOT_FINALIZED`で拒否する。
> 以下は当時の検討記録として残す。
- Depends on: `ACE-040`（stable run ID、terminal run record、artifact finalize）、`ACE-041`（retention／restart安全網）

## Context

現行`artifact_read` v1は、immutableな単一artifactを`range`、`tail`、`around`でlosslessに読む。しかし複数の
stdout／stderrを横断してpatternを探す、同じ検査の過去runと現在runを比較する、diagnosticだけを集約するには、
AI hostがhandleを一件ずつ再読して結果を再構成する必要がある。通常responseへ完全logを戻すのはtokenを浪費し、
各artifactを独立に切り詰めると後段のsourceを黙って見落とす。

Phase 4では`artifact_read` v2へquery actionを追加する。ただしartifactのraw bytesが一次証拠であり、検索index、
diagnostic、diffはそこから再生成できる派生物に限る。process lifecycleと増分logは`run_observe`が所有し、
`artifact_read`はACE-040が確定したterminal run recordとfinalized artifactだけを読む。

## Decision

### 1. 公開境界とv1互換

`artifact_read` v2は`action`に応じて次を返す。

| action | 成果 | 成功schema |
|---|---|---|
| `read` | 単一artifactのrange／tail／around | `aishell.artifact-read.v2`の`read` variant |
| `search` | 複数artifactを横断するliteral／regex match | 同`search` variant |
| `diagnostics` | 複数run／artifactの正規化diagnosticとparse coverage | 同`diagnostics` variant |
| `compare` | 明示baseline runとcandidate runのraw digest、line／diagnostic差分 | 同`compare` variant |

v1 inputのように`action`を省略し、`handle`と`mode: range | tail | around`を送った場合は`read`として扱い、
offset、length、tail lines、最初のliteral pattern、byte budgetの意味と既定値を変えない。
`AISHELL_SCHEMA_COMPAT=v1`ではこの経路のresultを`aishell.artifact-read.v1`のshapeで返す。v1の
`around`を全一致検索へ意味変更しない。v2の未知action／field、v1 fieldとv2 source selectorの混在は
`INVALID_ARGUMENT`とし、推測変換しない。

新しいactionは次のsourceを明示的な順序付き配列で受ける。

- `artifact`: immutable handleを一件指定する。既存v1 artifactはstore成功時点をfinalizedとみなす。
- `run`: ACE-040のstable `run_id`と`stdout | stderr | both`を指定する。terminal run recordが保持する
  finalized artifactをchannel、run内ordinal順へ展開する。

同じhandleを複数sourceが参照する時はraw走査を一回にdeduplicateするが、resultには全source provenanceを残す。
`search`／`diagnostics`は1〜64個のsourceを受ける。`compare`はstable run IDでbaselineとcandidateを一件ずつ
必須とし、「直近」「前回」のように実行中に意味が変わるselectorを持たない。別projectのrunを混在させず、
呼出runtimeのproject identityと一致しなければ`RUN_PROJECT_MISMATCH`で停止する。

### 2. finalize、identity、retention

ACE-040はrun開始時に変更されない`run_id`を発行し、terminal stateへ遷移する前にstdout／stderrをclose、fsync、
SHA-256計算してartifact metadataを確定し、そのmetadata digestをterminal run recordへ束縛する。新actionが
`queued | running | cancelling`のrunを受けた場合は部分logを検索せず`RUN_NOT_FINALIZED`を返し、観測先として
`run_observe`を示す。terminal recordは`passed | failed | timed_out | cancelled | interrupted`のいずれでもよいが、
そこから参照される全artifactがfinalized済みでなければrun全体を`ARTIFACT_NOT_FINALIZED`とする。

各queryは開始時にsource manifestを作り、run ID、terminal record digest、artifact handle、kind、size、SHA-256、
expires_at、channel、ordinal、provenanceを固定する。manifest中の最短`expires_at`をqueryの`expires_at`とし、queryは
source retentionを延長しない。処理中だけ選択artifactをGCからpinし、request終了後に解放する。retention中のraw
artifact、terminal record、source manifest、生成済みresult streamを容量都合で削除しない。容量を確保できない時は
開始前に`EVIDENCE_QUOTA_EXCEEDED`で停止し、古い一次証拠を追い出さない。

sourceのhandle／runが不明なら`HANDLE_NOT_FOUND`／`RUN_NOT_FOUND`、期限切れなら`HANDLE_EXPIRED`／`RUN_EXPIRED`、
metadataと実bytesのsize／SHA不一致、terminal record digest不一致、retention中の欠損は`EVIDENCE_CORRUPT`とする。
選択sourceの一部だけを除外して成功にしない。query中の期限到来は、そのrequestで取得したpinに限り走査完了まで保護する。
ただしresult stream完成時に最短source期限を過ぎていた場合は派生物を破棄して`HANDLE_EXPIRED`／`RUN_EXPIRED`で停止し、
取得不能なcontinuationを含む成功resultを返さない。

### 3. immutable result streamと共通budget

`search`、`diagnostics`、`compare`の初回requestは全sourceをstreaming走査し、header付きcanonical JSONLのimmutable
result stream artifactを作ってからresponseを返す。raw artifactは変更せず、result streamは派生証拠として
source manifest digest、query digest、parser／regex engine version、全bytes SHA-256を持つ。派生stream作成に失敗した
場合は結果0件として成功させずtyped errorで停止する。

`byte_budget`は1〜1,048,576 bytes、既定65,536で、result streamの完全なJSONL itemへだけ適用する。envelope、
source report、集計、cursor、artifact descriptorはbudget外とする。一itemを分割せず、次itemが収まらなければ0件でも
continuationを返す。`returned_bytes`、`omitted_bytes`、`has_more`、`continuation`、result stream handle／SHA-256／
expires_atを常に返し、silent truncationしない。全pageのitem bytesを順に連結するとresult streamのdata部と一致する。

opaque continuationはaction、canonical request、project identity、source manifest digest、result stream SHA-256、
次byte offset、expires_atへ認証付きで束縛する。改ざん／別requestへの流用は`INVALID_CONTINUATION`、retention失効は
`CURSOR_EXPIRED`、retention中の派生stream欠損は`EVIDENCE_CORRUPT`で停止し、sourceの再走査や先頭pageへ黙って
fallbackしない。artifactはimmutableなので通常の`CONTENT_CHANGED`は発生しない。metadata／run recordの変化は
corruptionとして扱い、同じstable IDで別内容を返さない。

### 4. search

`search`は1〜32個のqueryを受ける。各queryは一意なcaller指定`query_id`、`kind: literal | regex`、pattern、
`case: sensitive | insensitive`、前後0〜20行を持つ。literalはUTF-8 patternのbyte列をraw bytesからstreaming検索し、
一致byte offsetを正本にする。前後がUTF-8としてlosslessならtext、そうでなければbase64を返すため、binary artifactを
黙って除外しない。binaryのbase64 contextは一致byte列だけを返し、line contextを作れないことを
`context_state: binary_exact_match_only`で明示する。regexはUTF-8 textだけを対象とし、選択sourceの一件でもlossless UTF-8でなければ
`NOT_TEXT_ARTIFACT`で全queryを停止する。regex engine、Unicode／case-fold version、match／backtracking／pattern長の
上限をschema versionで固定し、上限超過は`QUERY_LIMIT_EXCEEDED`とする。

match itemはquery ID、artifact handle、全source provenance、run ID、channel、artifact ordinal、byte range、line／column、
context encoding／bytesを持つ。byte rangeは0-based半開区間、textのline／columnは1-based Unicode scalar位置とする。
deduplicate keyは`query_id + artifact SHA-256 + byte range`で、並びはrequest query順、
source初出順、artifact ordinal、match開始byte、終了byteとする。0件も正常結果だが、budget外の`source_reports`へ
各選択artifactの`scanned_bytes`、match数、encoding判定を必ず載せる。reportの欠落を「検索対象外」と解釈させない。

### 5. diagnostics

`diagnostics`はfinalized stdout／stderrをversion固定のadapterへstreaming入力し、共通schemaへ正規化する。
diagnostic itemは少なくともseverity、message、tool、code、file path、line／column range、run ID、channel、raw artifact
handle／byte range、adapter ID／versionを持つ。pathはrunのworking directoryとproject rootへ照合するが、許可root外や
解決不能のpathを捨てず、`path_state: resolved | outside_root | unresolved`とraw pathを返す。
severityは`error | warning | note | info | unknown`のclosed set、source rangeは1-based line／columnとし、不明値はnullにする。

`adapter: auto`はrun recordのexecutable／arguments／declared output formatだけで決定的に選び、本文の一部を見て別adapterへ
黙って切り替えない。対応adapterがなければ`unsupported` source reportを返す。adapterが認識しなかった行も捨てず、
各source reportに`total_bytes`、`parsed_bytes`、`unparsed_bytes`、`diagnostic_count`、`adapter_state`を載せる。
parse errorはraw byte range付きの`parse_error` itemとreportへ出し、result statusを`complete_with_parse_errors`にする。
各sourceの全byte rangeをparsed／unparsedのどちらかへ一度だけaccountし、一部sourceを結果から落とさない。ACE-060が
Xcode／xcresult、SARIF、Cargo JSON、Bazel BEP adapterを追加してもこの共通schemaとcoverage契約を変えない。

severityの別名統合、path解決、diagnosticの同一性判定以外にmessageや順序を正規化しない。deduplicate keyは
adapter ID／version、tool、code、resolved file identityまたはraw path、range、message digestで、同一diagnosticの
全provenanceを残す。並びはseverity、resolved path byte order、range、message digest、source初出順で決定的にする。
severity順は`error`、`warning`、`note`、`info`、`unknown`に固定する。

### 6. history compare

`compare`は明示したbaseline／candidate terminal runの同じchannelを比較する。両runのexecutable identity、arguments、
working directory identity、environment digest、toolchain binding、check／pipeline IDをenvelopeへ返し、一致しないfieldを
`binding_differences`へ列挙する。差があっても比較自体は禁止しないが、「同条件の回帰」とは表示しない。

`view`は次に限定する。

- `raw_digest`: stdout／stderrごとのsizeとSHA-256、および同一判定。binaryを含め常に利用できる。
- `lines`: channel別のlossless UTF-8 raw line sequenceに対するMyers diff。行末を含むraw bytesを同一性に使い、
  timestamp、path、色code、空白を暗黙にnormalizeしない。非UTF-8 sourceは`NOT_TEXT_ARTIFACT`で停止する。
- `diagnostics`: Section 5の同一adapter versionで得たdeduplicate keyを使い、`added | removed | unchanged`を返す。
  baselineとcandidateでadapter versionが一致しなければ`ADAPTER_VERSION_MISMATCH`とし再parseを促す。

line hunkまたはdiagnostic deltaをitemとして共通budget／continuationへ載せる。並びはchannel、artifact ordinal、baseline
位置、candidate位置、kindとする。等価でもraw digest、binding differences、source reportsを返す。比較途中で一方のrun、
artifact、channelを欠落扱いにして続行しない。

### 7. 責務境界と失敗

- `artifact_read`はprocessを待機、cancel、再実行しない。非terminal runは`run_observe`へ戻す。
- queryはraw artifactを更新せず、diagnostic indexやresult streamを一次証拠へ昇格させない。
- historyは明示run IDだけで比較し、labelや時刻からbaselineを推測しない。
- unsupported adapterをsource reportなしの空結果へせず、binary、parse error、expired／corrupt source、quota不足を
  silent skipまたは前回cacheへfallbackしない。
- pattern、regex、diffをshell文字列として評価せず、workerを使う場合もexecutableとargumentsを分離する。
- 通常resultへraw全文を複製しない。完全rawはv1互換`read`、完全派生結果はresult stream handleから取得する。

## Verification contract

- v1 `range`、`tail`、`around`の既存fixtureを無変更で通し、`AISHELL_SCHEMA_COMPAT=v1`のschemaとerrorを固定する。
- 2 run × stdout／stderrのsearchで、後順位artifactだけのmatch、0件、同handle重複、UTF-8境界、binary literal、
  regex＋binary error、case、前後行を固定する。全source reportの`scanned_bytes`合計をraw sizeから再計算する。
- byte budget N/N+1、先頭itemがbudget超過、複数pageを検証し、page連結がresult stream bytes／SHA-256と一致する。
  token改ざん、別query流用、期限切れ、retention中のstream欠損はそれぞれtyped errorになる。
- queued／running run、terminal record未確定、artifact未finalize、SHA不一致、source一件だけの欠損、quota不足で
  部分成功しないことを固定する。
- diagnosticsはsupported／unsupported／parse error／outside-root pathを含むfixtureで、全bytesが
  `total_bytes = parsed_bytes + unparsed_bytes`となり、parse-error rangeがunparsed内に含まれることを確認する。
- compareは同一run、追加／削除line、stdoutだけ同一、binding差、binary raw digest、binary lines error、diagnostic
  added／removed、adapter version mismatchを固定する。run IDを時刻順から推測しない。
- restart後もterminal run ID、raw handle、continuationがretention中に同じdigestを返す。実行中logは
  `run_observe`だけが返し、`artifact_read`から部分的に見えないことを確認する。
- 64 source、32 query、1MiB budgetの上限と上限+1をfocused testで固定し、巨大log fixtureはpeak memoryが
  source総bytesに比例しないstreaming実装であることを確認する。

## Consequences

ACE-044はACE-040／041のrun registryとfinalize順序を前提に、query compilerとresult stream storeを
`AIShellCore`へ実装し、MCP handlerにはprotocol変換だけを置く。ACE-040が未受入の間、ACE-042を実装開始しない。
既存`artifact_read`の単一readを削減せず、`artifact_read`一tool内のaction追加なのでdefault／full tool数も増やさない。
