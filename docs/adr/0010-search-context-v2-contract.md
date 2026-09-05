# ADR 0010: `search_context` v2契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-21
- Lattice task: `ACE-022`
- Control: `aishell-capability-expansion-20260721`

## Context

現行`search_context` v1は、一回につき一つの固定文字列を`rg --json`で検索し、件数とbyte budget内のmatchを
返す。continuationと`CONTENT_CHANGED`は持つが、複数query、regex、path glob、case指定、前後行を一回の
観測へ束ねられない。また変更fileの優先度はworkspace journalの直近集合へ暗黙依存しており、どのroot・cursor・
履歴範囲を根拠にした順位かをcallerが検証できない。queryごとのworker呼出しをAI hostへ戻すと、重複結果、
budgetの分断、検索間のfilesystem race、model/tool往復が再び増える。

Phase 2では検索を`ContextCompilerService`の一メソッドから専用`SearchContextService`へ分離し、lexical検索の
request、候補取得、dedup、ranking、共有budget、continuation、root freshnessを一つのdomain transactionとして
所有させる。`rg`とworkspace/project profileは直接worker/providerとして再利用し、MCP handlerへ検索ロジックを
置かない。

## Decision

### 1. 公開actionと互換境界

`search_context`は`aishell.search-context.v2`を返し、次のactionを持つ。

- `action: "search"`: `fixed`、`regex`、`glob` queryを同じrequestで実行するlexical検索。
- `action: "semantic"`: Phase 6で登録される明示semantic providerへ委譲する検索。providerが未登録、indexing中、
  staleの時はそれぞれtyped state/errorを返し、lexical検索へ切り替えない。

Phase 2で実装するbuilt-in providerは`rg-json-v1`とworkspace indexによる`search`だけである。`semantic`の
provider seamと失敗契約はこのADRで固定するが、provider本体を実装済みとは扱わない。

tool surfaceはADR 0003／0009と同じfeature gateへ従う。`AISHELL_CAPABILITY_SET`未指定時は高密度5 tool＋control 2の
default `tools/list` 7本、`AISHELL_TOOL_PROFILE=full`では既存full 25本を維持する。`expanded-v1`指定時だけdevelopment
9 tool＋control 2でdefault `tools/list` 11本、`expanded-v1`かつfullで29本とする。`search_context` v2実装を理由に
未指定defaultを11本へ早期切替したり、controlをdevelopment 9本へ数えたり、legacy toolを削って29本へ合わせたりしない。

v1の`query`、`path`、`max_results`、`byte_budget`、`continuation` inputは互換adapterで受理し、次のv2 requestへ
機械変換する。

- `action="search"`
- `queries=[{id:"q0", kind:"fixed", pattern:query, case:"sensitive", before_lines:0, after_lines:0}]`
- `path`があればその値、なければ`RuntimeConfiguration.primaryAllowedRootPath`（設定順の先頭）を検索rootとして
  明示解決する。v2 native requestの複数root時`ROOT_REQUIRED`をv1へ適用しない。
- `max_results=max_results`、`byte_budget=byte_budget`、`ranking=["changed"]`
- 変更集合は後述の非破壊retained observation viewから、v1が従来参照したlegacy recent-change windowを同じ順序・
  上限で射影する。viewが完全であることを確認できない時は空集合と見なさない。

ACE-023c着手前のbenchmark v2 freeze taskで、現行v1のinput default、primary root選択、`rg` fixed-string/case-sensitive検索、score 100/10、
score降順・path昇順・line昇順、件数・byte計算、`search1` continuation、全成功/error resultをcharacterization fixtureとして
凍結する。
v1 inputをv2 resultへ変換してもfixed-string、path、件数／byte budget、変更file優先、continuation、
`CONTENT_CHANGED`を失わず、凍結fixtureを変更しない。互換期間に`AISHELL_SCHEMA_COMPAT=v1`を指定した場合だけ旧result
shapeへ射影する。証拠不足やgapを成功へ丸めることだけは互換挙動ではなく既存のsilent-fresh defectなので、
`RESCAN_REQUIRED`／`CURSOR_EXPIRED`でfail closedする。v1 queryとv2
`queries`、初回fieldと`continuation`の同時指定、未知field、未知actionは`INVALID_ARGUMENT`で停止し、意味を推測しない。

### 2. lexical request

初回`search` requestは次を持つ。

- `path`: 許可root内の検索起点directory。省略時は、有効な許可rootが一つだけならそのroot、複数なら
  `ROOT_REQUIRED`とする。`path`は検索結果を限定するscopeであり、freshness ownerやcursor rootではない。
- `queries`: 1〜32件。各queryはrequest内で一意な`id`、`kind`、`pattern`を必須とする。
- `kind: fixed | regex`: file本文を検索する。`case: sensitive | insensitive | smart`、0〜20の
  `before_lines`／`after_lines`、省略可能な`include_globs`／`exclude_globs`を持つ。
- `kind: glob`: pathを検索する。`pattern`は後述の`aishell.path-glob.v1`とし、`case`、前後行、追加globは指定不可。
  ADR 0004のworkspace indexがcontent SHAまで照合したregular fileだけを返す。directory、symlink、gitlink、socket等を
  candidateにもresultにも含めない。
- `ranking`: `changed`、`tests`の重複しない配列。配列順を優先順とし、省略時は`["changed","tests"]`。
  空配列なら優先bucketを使わず、後述の決定的tie-breakだけを使う。
- `changed_since_cursor`: `changed`順位の下限となる同じrootのworkspace cursor。v2 inputで`changed`を要求する場合は
  必須とし、暗黙の「直近N件」を使わない。
- `max_results`: 全query共有で1〜500、既定50。
- `byte_budget`: v2 native requestでは全query共有で1,024〜1,048,576 bytes、既定65,536。v1 adapterは凍結済みの
  1〜1,048,576 clampと先頭match未収容errorをそのまま維持する。
- `continuation`: 直前resultのopaque token。指定時は`path`を含む他の初回fieldを同時指定しない。

freshness、workspace cursor、project profile、changed viewのownerはADR 0009と同じeffective allowed rootとする。
configured rootが重複する場合はcanonical pathのcomponent数が最大のroot、同数ならcanonical pathのUTF-8 byte order、
同pathなら`device:inode` identityのbyte orderで先頭を選ぶ。`path`がそのowner配下のsubdirectoryでもroot identityは
ownerのcanonical path、device/inode、allowed-root policy digestから作り、scopeの深さ、symlink spelling、検索queryで
変えない。resultは`effectiveRoot`と`searchScope`を別fieldで返し、cursorとprofileは前者、candidate filteringは後者へ
束縛する。v1でpathを省略した場合も、先にprimary allowed rootをscopeとして解決してから同じowner選択を行う。

`regex`はRust regexとして`rg`が受理する範囲、globは次のversioned文法`aishell.path-glob.v1`だけを受理する。

- pathとpatternはUTF-8のroot相対pathを`/`区切りで比較し、常にroot anchorとする。leading `/`、空segment、`.`、
  `..`、NULは不正である。case-sensitiveで、Unicode normalizationやlocale foldingを行わない。
- `*`は同一segment内の0文字以上、`?`は同一segment内の1文字に一致する。`**`はsegment全体である時だけ有効で、
  0個以上の完全segmentに一致する。segment内の`ab**cd`、3個以上連続する`*`は不正である。
- `[abc]`、`[a-z]`、先頭`!`による`[!abc]`を認める。rangeはASCII scalarの昇順だけ、閉じないclass、逆順range、
  空classは不正である。`\`は次のASCII meta文字`* ? [ ] ! - \`だけをescapeし、末尾escapeと`/` escapeを拒否する。
- dotfileは通常文字として`*`／`?`／classの対象になる。ただしADR 0004の除外規則により`.git`、`.build`、
  `node_modules`配下はindexに存在せず検索不能である。brace、extglob、platform固有separatorは扱わない。
- `src/**`は`src/`直下を含む任意深さのregular file、`**/name.swift`はroot直下を含む任意深さの同名fileへ一致する。
  同じ文法versionを本文queryの`include_globs`／`exclude_globs`にも使う。

不正patternは
query `id`付きの`INVALID_REGEX`／`INVALID_GLOB`とし、そのqueryだけをfixed-stringへ変換したり除外したりしない。
`smart` caseはpatternにUnicode uppercaseが一つでもあればsensitive、それ以外はinsensitiveと決定し、選択結果を
query evidenceへ残す。include globはOR、exclude globは常に優先する。

`SearchContextService`は各本文queryをshellを介さない`rg --json` workerとして直接起動する。queryごとのargv、
exit status、stdout/stderr digestを完全証拠へ残す。glob queryの候補は同じroot観測へ束縛されたworkspace indexから
取得する。indexにevent gap、root identity不一致、未照合offline変更がある時は`RESCAN_REQUIRED`とし、`find`や
`rg --files`による黙ったfull-scanへfallbackしない。本文検索をrequested scope全体へ実行する`rg` scanは
`scanMode: live_rg`として結果に明示し、fallbackとは扱わない。

`semantic` requestも`path`、`queries`、`provider`、`cursor`、共有limitsを使う。各queryは一意な`id`、
`kind: semantic`、symbol/textの`pattern`、`operation: definition | references | workspace_symbols`を持つ。
provider固有parameterは公開top-levelへ展開せず、登録時にversion付きschemaを持つ`provider_options`だけへ置く。
lexical kindとsemantic kindを一requestへ混在させない。

### 3. match identity、context、dedup

公開`canonicalIdentity`は固定長64文字の小文字hex SHA-256とする。本文matchは次のidentity descriptorをRFC 8785
JSON Canonicalization Scheme（JCS）でencodeしたbytes、glob matchは`byte_start`、`byte_end`、`content_sha256`を除いた
同schemaのdescriptor bytesへSHA-256を掛ける。

```json
{"byte_end":42,"byte_start":36,"content_sha256":"<sha256>","file_identity":"<device:inode>","kind":"text","path":"<effective-root-relative-path>","root_identity":"<effective-root-identity>","schema":"aishell.search-match-identity.v1"}
```

identity descriptorの完全bytesはevidence artifactへ保持し、resultの`canonicalIdentity`へpathやdescriptor本文を埋め込まない。
長いpathは`pathDigest=SHA-256(UTF-8 path bytes)`とartifact内descriptorを照合して検証し、digestからpathを復元したり
切り詰めたpathでidentityを再計算したりしない。同じ場所が複数queryに一致した場合は一件へdedupし、UTF-8 byte orderの
`queryIds`、queryごとのmatched range、選択されたcase modeを保持する。path文字列や表示textだけで同一視しない。
hard link、rename、同文行を誤って統合せず、同一queryから重複した同一byte rangeだけは一件にする。

本文matchの正規rangeはfile先頭から数えたUTF-8 byteの0-based half-open
`byteRange: {start, end}`とし、`0 <= start < end <= fileSize`を満たす。表示用の`line`は1-based、`columnBytes`は
その行先頭からの0-based UTF-8 byte offsetだが、identityとcontinuationは`byteRange`だけを使う。queryごとの
matched rangeも同じ座標系にする。前後行はfileを一度だけ
直接読んでSHAを照合した後、各query指定の最大範囲まで作る。同fileで重なるcontext windowは一つの
`contextBlock`へ併合し、matchは`contextBlockId`を参照する。binaryまたはlossless UTF-8でないfileを本文queryが
返した場合は`NOT_TEXT_FILE`とし、置換文字やbytes省略で成功にしない。glob matchはline、column、contextをnullにする。

完全candidate列はdedup後、callerが`ranking`へ指定した各criterionのboolean bucketを配列順に比較し、その後
queryの入力順、root相対pathのUTF-8 byte order、`byteRange.start`、`byteRange.end`で並べる。glob matchはrangeの
代わりに0を使う。`changed` bucketは
`changed_since_cursor`以後に作成・変更・rename・削除元／先として観測されたfile、`tests` bucketは同じroot/cursorへ
束縛されたproject profileのknown test target/pathを先頭にする。一致したqueryが複数なら最も早い入力indexを使う。

`changed`の正本はACE-043の`workspace_wait`と共有するroot-scoped非破壊retained observation viewである。このviewは
`rootIdentity + fromCursor + throughCursor`でimmutableな変更区間を読み、consumerごとのreadでjournal headや他consumerの
cursorを進めない。同じviewを複数search、wait、snapshotが同時に読めなければならず、一方の読取が他方のchanged集合を
空にしてはならない。retention不足は`CURSOR_EXPIRED`、event gap/root identity置換/未照合offline変更は
`RESCAN_REQUIRED`とし、空のchanged集合を返せるのはviewが区間の完全観測と変更0件を証明した時だけである。

複数bucketが同点なら後続keyへ進む。scoreへ不透明な重みを足さない。resultの`rankingEvidence`は、適用順、
workspace cursor、observation-view ID、from/through cursor、changed-set digest、project-profile digest、test分類の
`complete | partial | unavailable`を返す。
`tests`を要求してprofileがpartialでも既知testだけは順位付けできるが、完全性を`complete`と表示しない。
profile unavailableをfilename heuristicへ黙って置換しない。

### 4. 共有budget、完全証拠、continuation

全queryのdedup・ranking後に一つのordered item streamを作る。itemは`match`または、最初に参照される時だけ置く
`contextBlock` recordである。request、identity descriptor、stream record、`oversized` descriptor、observer projectionを
含む本契約の「canonical bytes」はすべてRFC 8785 JCSだけで生成する。単一JSON valueは`JCS(value)`そのもの、item streamは
各`JCS(record)`の直後へ一個のLF byte（`0x0A`）を置き、最終recordもLFで終える。pretty print、encoder固有key順、Unicode
normalization、platform改行をcanonical bytesへ使わない。JCSで表現不能なnumber/stringは`RESULT_ENCODING_FAILED`とする。

新しいcontextBlockとそれを最初に参照するmatchは一つのpagination bundleとして隣接させ、片方だけをpageへ返さない。
このJCS+LF item stream bytesだけを`byte_budget`へ算入し、envelope、集計、freshness、evidence descriptor、continuation
tokenはbudget対象外とする。一recordを分割しない。

`max_results`は返したunique match件数へ適用し、contextBlock件数には適用しない。次itemまたは次matchが収まらない時は
通常bundleを次pageの先頭へ送れる場合は、そのbundle直前まででpageを閉じる。pageの先頭bundleがrequest budget又は
公開最大1,048,576 bytesを超える場合は、同じ位置を指すcontinuationを返して停止してはならない。完全bundleをartifactへ
保持した上で、JCS+LFで512 bytes以下のcanonical `oversized` descriptorをbudget内itemとして返し、stream offsetをbundle直後へ
必ず進める。descriptorは`kind: oversized`、`reason: request_budget_exceeded | maximum_budget_exceeded`、
`canonicalIdentity`、`pathDigest`、`byteRange`、`requiredBytes`、完全artifactのhandle／SHA-256／size／`expires_at`を持つ。
handleとdigestは固定長表現とし、descriptor生成自体が512 bytesを超える場合は`RESULT_ENCODING_FAILED`で停止する。
巨大な単一行、最大前後行、長いpathをinline truncationせず、complete artifactを唯一のlossless取得先として明示する。

`oversized` descriptorは対応match一件を消費したものとして`returnedMatches`へ数え、`matches`とは別の
`oversizedDescriptors`へ置く。`omittedMatches`へ二重計上しない。後続bundleが無ければcontinuationはnull、あれば進んだ
offsetを指すため、同じrequestの反復で同じoversized itemを無限に返さない。`returnedBytes`は返した通常itemとdescriptorの
bytes、`omittedBytes`は同じfrozen streamに残る未返却inline item bytes、`omittedMatches`は未返却unique match数とし、
独立再計算可能にする。silent truncationは禁止する。

完全なquery request、root binding、worker evidence、dedup前candidate、dedup/ranking後streamを`expires_at`付きartifactへ
保持し、artifact SHA-256をresultへ返す。advertised retention中に一次証拠を削除しない。request digestは初回requestの
RFC 8785 JCS bytesへ掛けたSHA-256とする。continuationはこのartifact、request digest、provider/version、root identity、
root cursor、全参照fileのidentity/SHA、次item offsetへ
MAC相当のprocess-local secretで束縛する。token改ざんは
`CURSOR_EXPIRED { details: { reason: "integrity_mismatch" } }`、artifact失効は
`CURSOR_EXPIRED { details: { reason: "artifact_expired" } }`、
query、provider、provider version、初回limitsとの不一致は
`CURSOR_EXPIRED { details: { reason: "request_mismatch" } }`、
root cursorまたは参照fileの変化は`CONTENT_CHANGED`とし、検索の再実行や先頭pageへfallbackしない。

### 5. root-scoped freshnessとrace

初回request開始前に、ADR 0009のowner規則で選んだeffective rootのidentity、allowed-root policy digest、workspace
generation/cursor、event-gap stateを取得する。`path`はそのroot内のsearch scopeとして別にcanonicalizeする。
候補取得とcontext読取の終了後に同じ値を再取得し、途中で変化した場合は部分結果を返さず`CONTENT_CHANGED`とする。
他のconfigured rootの更新はこのrequestを失効させない。resultは`freshness` objectとして少なくとも
`effectiveRootIdentity`、`effectiveRootPolicyDigest`、`searchScope`、`workspaceCursor`、`observedFrom`、
`observedThrough`、`state: fresh`、provider evidence digestを返す。
`filesystem-current`という根拠なし文字列だけでfreshを主張しない。

workspace cursorの形式、root、除外規則、generation、sequence、retentionに関する失敗codeはADR 0004どおり
`CURSOR_EXPIRED`へ統一し、`details.reason`を
`malformed | integrity_mismatch | request_mismatch | root_mismatch | exclusion_mismatch | generation_mismatch | future_sequence | retention_expired | artifact_expired`
のclosed setで返す。callerはreason文字列ではなくcodeで再取得要否を分岐でき、telemetryと診断ではreasonを使える。
root identity置換とevent gapはcursor syntax errorへ丸めず`RESCAN_REQUIRED`とする。journal gapを空のchanged集合として
扱わない。worker timeout、output上限、起動失敗、非0/1 exit、JSON破損、
artifact発行失敗は`WORKER_TIMEOUT`、`OUTPUT_LIMIT_EXCEEDED`、`WORKER_UNAVAILABLE`、`WORKER_FAILED`、
`WORKER_OUTPUT_INVALID`、`ARTIFACT_STORE_FAILED`で停止する。成功したqueryだけのpartial result、前回cache、別providerを
返さない。

`semantic` actionも同じroot identity、cursor、file SHAへprovider document version/index generationを加えて束縛する。
provider指定は必須で、`unavailable`は`PROVIDER_UNAVAILABLE`、`indexing`は機械判定可能なnon-terminal state、
staleは`PROVIDER_STALE`とする。semantic失敗時のlexical fallbackはcallerが別の`search` requestとして明示した場合だけ
許され、同じresult内で自動実行しない。

### 6. 実装前dependency gate

Lattice plan revisionは、`WorkspaceDeltaJournal` seamを実装する独立taskを追加し、Phase 2のsearch統合task
`ACE-023c`とPhase 4の`ACE-044`の共通predecessorにする。このtaskはeffective-root ownerごとのimmutable retained
observation view、from/through cursor read、retention floor、gap/corruption state、複数consumerの非破壊fan-out APIを
`AIShellCore`へ置き、snapshotの破壊的consumeと`recentChangedPaths`直参照をsearch pathから除去する。検索専用journal、
wait専用journal、handler内copyを別々に作らない。taskのfocused gateは同じviewを2 search＋1 snapshotが読んでもhead、
retention、result digestが変わらないことと、restart後も同じ区間を再生できることとする。このpredecessorがdoneになる前に
`ACE-023c`又は`ACE-044`を開始・受入しない。

さらに、後述のexact v2 request、observer projection、schema、materializer、fixture digestを固定する独立benchmark v2
freeze taskを`ACE-023c`のpredecessorにする。freeze taskは実装candidateを起動せず、F契約から入力とharness-only oracleを
生成し、review済みdigestをevidenceへ残す。統合実装はfreeze済みbytesを変更してから通すことを禁止し、変更が必要なら
別F revisionと再freezeを要求する。既存benchmark v1のschema、fixture、prompt、oracle、materialized request、digest、
保存済みresultはbyte-for-byte不変であり、v2値を後付けしない。

## Verification contract

統合benchmark `batch-context-multi-query`のcandidate armはsetupでfull snapshot cursorを取得し、次のv2 request objectへ
`path`と`changed_since_cursor`の実値だけを注入する。modelがqueryごとに別callを作るrequestへ置換しない。

```json
{
  "action": "search",
  "path": "<fixture-root>",
  "queries": [
    {"id":"fixed-needle","kind":"fixed","pattern":"needle","case":"sensitive","before_lines":0,"after_lines":0},
    {"id":"regex-export","kind":"regex","pattern":"export\\s+const","case":"sensitive","before_lines":0,"after_lines":0},
    {"id":"glob-src","kind":"glob","pattern":"src/**"},
    {"id":"glob-test","kind":"glob","pattern":"test/**"}
  ],
  "ranking": ["changed", "tests"],
  "changed_since_cursor": "<setup-cursor>",
  "max_results": 500,
  "byte_budget": 65536
}
```

observer projectionはraw v2 resultを変更せず保存した後、次のfieldだけを同名でRFC 8785 JCS objectへ写す。projectionの
canonical bytesは末尾LFなしの`JCS(projection)`である。array順はraw result順、`queryCoverage`だけはUTF-8 byte orderで
unique sortする。`recomputedBytes`は返却された通常itemとoversized descriptorそれぞれのJCS bytes＋LF 1 byteをobserverが
独立合計する。`canonicalIdentity`は64文字の小文字hexだけを受理し、identity artifactのJCS descriptorをSHA-256で再計算する。

```json
{
  "schema": "aishell.search-context-benchmark-projection.v2",
  "taskId": "batch-context-multi-query",
  "matchedPaths": "matches[].path",
  "canonicalIdentities": "matches[].canonicalIdentity + oversizedDescriptors[].canonicalIdentity",
  "deduplicated": "count(canonicalIdentities) == count(unique(canonicalIdentities))",
  "queryCoverage": "sort(unique(flatMap(matches[].queryIds)))",
  "returnedBytes": "result.returnedBytes",
  "recomputedBytes": "sum(byteCount(JCS(item)) + 1)",
  "budgeted": "returnedBytes == recomputedBytes && returnedBytes <= 65536",
  "hasMore": "result.hasMore",
  "continuationPresent": "result.continuation != null",
  "continuationConsistent": "hasMore == continuationPresent",
  "freshnessState": "result.freshness.state"
}
```

freeze taskはplaceholderへ実path/cursorを注入したRFC 8785 JCS exact request bytes、上記JCS projection schema bytes、
両SHA-256を同じevidenceへ固定する。期待pathと4 query IDはharness-only oracleに照合し、model-visible resultへexpected値を
混ぜない。v1 armはこのv2
objectを受理できないことをfailureにせず、凍結した単一fixed-string request/resultだけでcharacterizationする。

- `batch-context/multi-query` fixtureでfixed `needle`、regex `export\\s+const`、glob `src/**`／`test/**`を一requestにし、
  期待path、query関連付け、duplicate identity 0件、worker argv evidenceを検証する。
- 同一matchへfixed/regexが重なるfixture、同文別file、hard link、rename、重複context windowを固定し、dedup identityと
  `queryIds`、context併合を検証する。
- sensitive／insensitive／smart、Unicode uppercase、不正regex、不正glob、include/exclude競合、root escapeを固定する。
  globは`*`／`?`／`**`／class／escape／anchor／dotfileを個別に通し、symlink、gitlink、directoryが0件であることを確認する。
- changed-only、test-only、changedかつtest、その他の順位とtie-breakを固定し、別rootの変更ではcursorが失効せず、
  同rootの追加match、削除、内容変更、journal gapではtyped errorになることを確認する。同じretained observation viewを
  2 search＋1 waitが異なる速度で読んでもchanged集合が同一で、読取が相互消費されないことを固定する。
- byte budget N/N+1、`max_results`境界、全page連結を検証し、RFC 8785 JCS+LF item streamから
  `returnedBytes`／`omittedBytes`と
  完全stream SHAを独立再計算する。request budget超、最大budget超のcontext bundle、1 MiB超の単一行を固定し、各々が
  予算内`oversized` descriptorと読取可能な完全artifactを返し、次continuation offsetが必ず増えることを確認する。
- continuation改ざん、retention失効、query/provider/version不一致、page間変更、worker timeout/output超過/JSON破損で
  指定errorになり、再scan、再検索、partial query success、silent truncationが0件であることをtelemetryでも確認する。
- identity descriptorのJCS bytesから`canonicalIdentity`を独立再計算し、長path、Unicode、key挿入順、改行差、数値表現差で
  digest又はbudget計数がplatform間で変わらないことを固定する。
- malformed、別root、除外規則不一致、generation不一致、未来sequence、retention失効がすべて`CURSOR_EXPIRED`となり、
  `details.reason`だけが契約どおり異なることを固定する。
- v1 fixed-string inputを同fixtureへ通し、path、match順、budget、continuation、変更優先、`CONTENT_CHANGED`が非回帰である。
  path省略時のprimary root、1 byte budgetを含む`AISHELL_SCHEMA_COMPAT=v1`射影、capability未指定default 7／full 25、
  `expanded-v1` default 11／full 29のtool catalogも非回帰にする。
- Phase 6のsemantic fixtureはfresh referenceをfile SHA/document version付きで返し、stale-after-editで
  `PROVIDER_STALE`か明示stale stateとなり、silent lexical fallback 0件であることを確認する。

ADRだけのACE-022ではSwift testを実行せず、Markdown、既存ADR 0003・代表fixtureとのfield/action整合、diffを確認する。
実装時のACE-023cは`SearchContextService` focused testとMCP initialize、`tools/list`、成功・失敗result fixtureを通す。

## Consequences

共通journal seamとbenchmark v2 freezeの両predecessor受入後、ACE-023cは`SearchContextService`を`AIShellCore`へ追加し、
`DevelopmentRuntimeService`は委譲、`AIShellMCP`はschema変換だけを
行う。既存`ContextCompilerService.searchContext`は互換adapterへ縮退させず、専用serviceへのv1変換入口として残す。
Phase 2で新しい公開toolは追加しない。capability未指定default 7／full 25、`expanded-v1`のdevelopment 9＋control 2＝
`tools/list` 11／full 29を維持し、既存5 toolとlegacy surfaceの能力を削減しない。

変更/test順位の根拠と検索snapshotが明示されるため、AI hostは複数queryを一回で実行しながら、結果が空だった理由と
continuationのfreshnessを機械判定できる。代わりにSearchContextServiceはfrozen evidenceをretention中保持し、
workspace/project-profile contractと同じeffective-root owner・cursorを共有し、search scopeをowner identityから分離しなければ
ならない。
