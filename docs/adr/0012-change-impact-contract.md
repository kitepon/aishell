# ADR 0012: change impact候補とfreshness契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-21
- Lattice task: `ACE-032`
- Control: `aishell-capability-expansion-20260721`

## Context

変更fileから参照、依存先、関連test、build targetを調べるには、現状はAI hostが`rg`、manifest、test配置を
個別に読み、結果が現在のworktreeと一致するかも自分で照合する必要がある。単に複数providerの結果を結合すると、
古いindexや曖昧なsymbol名を「影響範囲」と誤認し、必要なcheckを落とす危険がある。

`change_impact`は完全な静的解析器でもtest selectorでもない。OS現在状態へ束縛された入力から、検証可能な根拠付きの
候補を一度に返すread-only toolである。Phase 3では候補提示だけを行い、test/buildの選択と実行はcallerの明示操作へ
残す。

## Decision

### 1. 公開境界と入力

`change_impact`の統合schemaは`aishell.change-impact.v2`とする。本ADRはADR 0003で予約した
`aishell.change-impact.v1`をversioned amendmentし、tool名、責務、公開順、feature gateは変えない。
requestは次を持つ。

- `operation`: 初回requestで`analyze | recommend`のclosed setから必須。continuation requestではtokenから継承する。
  ACE-032が確定する現契約は`analyze`だけであり、
  `recommend`はACE-033用の予約値とする。
- `root`: configured workspace root。省略時もsessionへ一意に束縛済みのrootが必要である。
- `workspace_cursor`: 呼出側が観測した`workspace_snapshot` cursor。必須。
- `changed_paths`: 変更されたroot-relative pathの配列。各要素は`path`と、既存fileなら`content_sha256`、
  削除済みなら`expected_absent: true`を持つ。
- `changed_symbols`: 変更symbolの配列。各要素は`path`、`content_sha256`、`name`、UTF-8 byte単位の
  `start_offset`／`end_offset`を必須とし、利用できる場合だけlanguage固有の`stable_id`を加える。
- `required_providers`: callerが結果に必須とするprovider ID。省略時は利用可能なproviderだけで部分結果を返す。
- `byte_budget`: evidenceを含む候補列へ共有する1〜1,048,576 bytes。既定65,536。
- `continuation`: 直前resultまたはbudget errorが発行したopaque token。continuation requestは`continuation`と
  省略可能な`byte_budget`だけを許可し、root、cursor、input、provider等の再指定を禁止する。

`changed_paths`と`changed_symbols`の少なくとも一方を必須とする。同じpathは正規化後にdeduplicateするが、
path入力とsymbol入力は統合せず、それぞれを候補根拠へ残す。bare symbol nameだけの全workspace探索は受け付けない。
symlinkを辿った実体、case normalization、root containmentはworkspace runtimeと同じ規則を使い、root外参照は
`PATH_OUTSIDE_ALLOWED_ROOT`で停止する。

`operation: analyze`のrequest/result/item closed setは本ADRだけを正本とする。`operation: recommend`のraw v2 request追加field、
envelope scalar、item kind、global order、budget/continuationへの組込みはACE-033が、同じpre-release
`aishell.change-impact.v2`を初めて公開する前にclosed setとして確定する。それまでは`recommend`をtool schemaの予約enumとして
認識してもtyped `NOT_READY`（`operation: recommend`、`ownerTask: ACE-033`、`nextAction`付き）で停止し、analyze item、
manifest推測、legacy projectionから合法なrecommend resultを捏造しない。operation欠損またはenum外は
`INVALID_OPERATION`とする。

凍結済み`representative-suite.v1`、`representative-execution-contracts.v1`、request template `impact`は比較条件なので
書き換えない。v1 fixtureの`changed_paths: string[]`と`providers: string[]`はbenchmark adapterだけが凍結形のまま
評価する。製品統合fixture v2では`workspace_cursor`、path/SHA object、`required_providers`へcutoverし、v1入力を
製品runtimeが暗黙受理してSHAなし解析へ退行しない。benchmark v1と統合v2の結果を同一schemaの測定値として混ぜない。

このbenchmark v1 adapterの実装所有taskはACE-034、凍結suiteでの実行所有taskはACE-070とする。adapterは過去freezeを
再生するためだけに存在し、全Fの製品統合v2が唯一の正道である。各attemptのtrusted setup phaseでproduction
workspace runtimeからroot identity、workspace cursor、各`changed_paths`の現在SHA/absenceを取得し、そのsetup evidence
digestをtimed phase開始前に固定する。adapterは凍結v1 requestのpathとprovider IDをこのtrusted setup evidenceへ
exact joinし、v1 `action`を同名のv2 `operation`、path/providerをv2のpath/SHA objectと`required_providers`へ
機械変換して、同じproduction `ChangeImpactService`へforwardする。
未一致path、欠損SHA、cursor変化はattempt setup failureであり、推測や再scanで補完しない。

serviceのraw v2 resultは一切書き換えず保持し、adapterはbenchmark observerが凍結済み判定を行うために必要なfieldだけを
v2からv1へ投影する。oracle、expected impacted path、agent reportをrequest生成・結果補完・projectionへ参照しない。
attempt traceは順序付きで、(1) exact v1 request bytesとSHA-256、(2) trusted setup evidence digest、(3) exact v2 request bytesと
SHA-256、(4) raw v2 result bytes、全page token chain、完全artifact SHA-256、(5) projected v1 result bytesとSHA-256を記録する。
projection後の値からraw v2 resultを捏造せず、v1 request → v2 request → raw v2 result → v1 projectionを追跡可能にする。

v1 projection envelopeは全scopeで`schemaVersion: "aishell.change-impact.v1"`を必須とする。全v2 pageを連結して
artifact SHAと一致させた後、凍結v1 requestの`action`だけでprojection scopeを選ぶ。ACE-032所有の`action: analyze`では
payloadを次の4 fieldだけから作る。

- `impactedPaths`: `candidate` itemのうち`references`、`dependencies`、`related_tests` categoryで、subjectが
  root-relative pathを直接持つものからそのpathを取り、unsigned UTF-8 byte順でsort・deduplicateしたstring配列。
  symbol subjectはそのsymbol pathを使う。manifest IDだけのtest/module/package/targetはpathへ推測変換しない。
- `provenance`: `impactedPaths`へ採用したcandidateに`candidate_evidence`で結ばれた`evidence`の`providerID`を
  unsigned UTF-8 byte順でsort・deduplicateし、ASCII comma 1文字でjoinしたstring。0件なら空文字とする。
- `unknowns`: raw v2 streamにある`coverage_gap` itemの件数を、そのまま非負整数で返す。
- `silentCompletenessClaims`: raw v2 envelopeが`coverage: complete`なのに`coverage_gap`が1件以上なら`1`、
  それ以外は`0`。矛盾をprojection時に修復したりgapを追加したりしない。

analyze projectionのtop-level keyは`schemaVersion`とこの4 fieldのclosed setであり、focused fieldその他を追加しない。
candidate category、provider、path、gapの別解釈をadapterへ許さない。参照先のないedge、未知candidate ID、
artifact/page不一致は`BENCHMARK_PROJECTION_INVALID`でattemptを失敗させ、値を補完しない。

同じlegacy toolを使うACE-033の`action: recommend`はanalyzeの拡張ではなく、別の予約projection scopeとする。
ACE-033の統合契約は公開前にraw v2 recommend resultのclosed setを確定し、test path selectorならroot-relative `path`を持つ`focused_check` itemと、
固定scalar `executionPolicy: explicit_run_check_only`を供給しなければならない。recommend projection payloadは次の2 field
だけを機械生成する。

- `recommendedChecks`: `focused_check` itemのうちselector kindが`test_path`の`path`だけをunsigned UTF-8 byte順で
  sort・deduplicateしたstring配列。label、check ID、target名からpathを推測しない。
- `executionRequiresOptIn`: raw v2 envelopeの`executionPolicy`が`explicit_run_check_only`なら`true`。
  field欠損または他値はfalseへ丸めず`BENCHMARK_PROJECTION_INVALID`とする。

recommend projectionのtop-level keyも`schemaVersion`、`recommendedChecks`、`executionRequiresOptIn`のclosed setである。
analyzeの4 fieldをrecommendへ、recommendの2 fieldをanalyzeへ混在させない。未知action、scope外field、同一requestでの
複数actionは`BENCHMARK_PROJECTION_INVALID`とする。これらの予約item/envelopeを製品統合へ定義する所有taskはACE-033、
legacy projection adapterへ実装する所有taskはACE-034であり、ACE-032はrecommend候補の意味や順位を変更しない。
ACE-033のraw closed setが未確定の間、凍結v1 `action: recommend` adapterもv2 `operation: recommend`の`NOT_READY`を
そのままattempt failureとして記録し、`recommendedChecks`や`executionRequiresOptIn`を生成しない。

### 2. freshnessの正本

freshnessの正本はprovider自身のtimestampやindex世代ではなく、workspace runtimeがOS現在状態との照合で確定した
root identity、generation、cursor、各fileのcontent SHA-256である。request開始時に次を照合する。

1. `workspace_cursor`が同じroot identityと現行generationに属すること。
2. 全`changed_paths`／`changed_symbols`のSHAまたはabsenceが現在のOS状態と一致すること。
3. 解析中に読んだmanifest、source、test、provider inputのSHAが結果確定時にも一致すること。

1または2の不一致は候補を返さず`CONTENT_CHANGED`、cursor retention失効は`CURSOR_EXPIRED`、event gapまたは
OS照合不能は`RESCAN_REQUIRED`とする。3の不一致も部分結果へせず`CONTENT_CHANGED`とする。先頭からの再scan、
古いsnapshot、Git状態、provider cacheへ黙って切り替えない。

result envelopeの`freshness`は`rootIdentity`、`workspaceGeneration`、`inputCursor`、`observedCursor`、全bindingの
canonical digestと件数だけを持つ。入力と解析対象の各`path`／`contentSHA256`は後述の共有page streamへ
`freshness_binding`一件ずつとして収め、budget外の可変長配列を作らない。continuationは完全binding、byte budgetを除く
semantic request、次item offset、provider state digest、直前budgetへ束縛する。continuation requestで`byte_budget`を
省略した時は直前budgetを再利用し、指定時は直前budget以上かつ1,048,576以下だけを許可する。それ以外のfield併記や
budget縮小は`INVALID_CONTINUATION_REQUEST`とする。token改ざんは`INVALID_CONTINUATION`、状態変化は
`CONTENT_CHANGED`とする。

### 3. providerの役割と状態

providerは候補生成器であり、freshnessの権威ではない。各provider reportは安定した`providerID`、`kind`、`version`、
`status`、`inputDigest`、`observedAtCursor`を持つ。`status`は次のclosed setとする。

- `fresh`: OS SHAへ束縛した入力だけで候補を生成した。
- `stale`: index/document version等が現在のOS SHAへ束縛できない。候補へ採用しない。
- `unavailable`: executable、index、対応言語、manifest等が利用できない。
- `unsupported`: providerが対象ecosystemまたはquery kindを契約上扱わない。

`stale`／`unavailable`／`unsupported`は`reasonCode`と上限付き`nextAction`を持つ。別providerへ切り替えたように
見せず、試行したproviderは後述の共有page streamへ`provider_report`一件ずつ収める。`required_providers`の一つでも
`fresh`でなければ候補を返さず`REQUIRED_PROVIDER_NOT_FRESH`とする。このerror resultもprovider別状態を同じbudget、
continuation、完全artifactで返す。必須指定がない場合はfresh providerの候補だけを返し、envelopeを
`coverage: partial`として不足理由を`coverage_gap` itemで明示する。候補0件を「影響なし」へ読み替えない。

Phase 3で利用するproviderは、workspace file identity/index、project profileのmanifest/target宣言、直接起動する
決定的なlexical searchに限定する。SourceKit-LSP、depfile、build graph等の後続providerは実装・SHA bindingが
成立するまで`unavailable`または`unsupported`であり、推測結果をsemantic evidenceとして返さない。Phase 6で
providerを追加しても本schemaとOS freshness authorityは変えない。

### 4. 候補、edge、根拠

resultは次の4 categoryを独立に返す。

- `references`: changed symbol/pathを参照するsource候補。
- `dependencies`: changed inputへ依存するsource、resource、module/package候補。
- `related_tests`: 変更に関連するtest file、suite、case候補。
- `build_targets`: 変更を含む、または依存edgeから到達するbuild/test target候補。

各候補は`candidateID`、`category`、対象を表す`subject`を持つ。候補とevidenceの対応は可変長`evidenceIDs`配列を
候補へ埋め込まず、`candidate_evidence` itemを一edgeずつ返す。`subject`はcategoryに応じてroot-relative path、
symbol locator、manifest由来のtarget/test IDを使い、表示名だけをidentityにしない。
候補順は`category → subject kind → canonical identity byte order → candidateID`で決定的にする。

各evidenceは少なくとも次を持つ。

- `evidenceID`と`providerID`
- 起点input IDと候補subject ID
- `relation`: `semantic_reference | lexical_reference | declared_dependency | contains_source | contains_test | naming_heuristic`
- 根拠位置の`path`、`contentSHA256`、byte range、またはmanifest edge identity
- `evidenceStrength`: `heuristic | lexical_match | semantic_match | declared_edge`のclosed ordinal
- 人が判断できる短い`summary`

異なるproviderの同一subject候補は一件へdeduplicateして全evidenceを保持する。heuristicは宣言edgeと同格に
昇格させない。`evidenceStrength`の順序は`heuristic < lexical_match < semantic_match < declared_edge`だけであり、数値confidence、
確率、重み付きscoreを生成しない。複数根拠を集約してordinalを加算したり、完全性の保証へ変換したりもしない。
ACE-033がfocused check候補を順位付けする時も、このclosed ordinalと個別根拠をそのまま使う。
filesystem providerがtest file名から`naming_heuristic`を生成する場合、変更fileのstemはtest basenameの
非英数字境界で区切られた完全token、またはstemへ`test | tests | spec | specs`を直結したbasename全体とだけ一致させる。
任意substring一致は使わない。たとえば変更file `a.mjs`に対して`a.test.mjs`は候補になるが、
`unrelated.test.mjs`は候補にしない。解析中に読んだ非一致test fileもfreshness bindingには残す。
referenceはsymbolのstable IDがない場合、同名tokenの
lexical candidateに留める。dependencyの向き、testとproduction targetの区別、直接／推移edgeを明示し、
循環はvisited identityで打ち切る。推移探索にはrequest/resultで可視な上限を設け、上限到達を
`coverage_gap` itemへ記録する。

### 5. budget、完全証拠、実行境界

ACE-032 analyze scopeのprimary responseでは、可変長情報を単一の`items`配列だけに置く。item kindは`input_path`、`input_symbol`、`required_provider`、
`freshness_binding`、`provider_report`、`coverage_gap`、`candidate`、`evidence`、`candidate_evidence`のclosed setとし、
各itemは可変長配列を内包しない。requestの全changed path/symbol/required provider、解析対象の全path/SHA、
全provider report、全gap、全candidate/evidence/edgeを決定順のcanonical JSONL streamへ一件ずつ含める。

`byte_budget`はこのstream全体で共有し、一itemを分割しない。result envelopeは固定上限のscalar、category別固定keyの
件数、`returnedBytes`、`omittedBytes`、`hasMore`、`continuation`、artifact descriptorだけを持つ。
上限は次で固定する。

- canonical request全体は4,194,304 bytes以下。
- `changed_paths`は4,096件、`changed_symbols`は4,096件、`required_providers`は64件以下。
- pathとstable IDは各4,096 UTF-8 bytes、symbol nameは1,024 bytes、provider ID／reason code／category IDは256 bytes、
  `summary`／`nextAction`は各4,096 bytes以下。
- canonical JSONL itemは改行を含め16,384 bytes以下、`items`は4,096件以下、`byte_budget`は
  1〜1,048,576 bytesとする。

requestまたはfield上限超過は`REQUEST_TOO_LARGE`、生成item上限超過は`RESULT_ITEM_TOO_LARGE`とし、切詰めない。
次の一item自体がrequestの`byte_budget`を超える場合は`BYTE_BUDGET_TOO_SMALL`、そのitemのcanonical JSONL byte数である
`requiredMinimumBytes`、同じitem offsetを指す新しいrecovery continuationを返す。callerはsemantic fieldを再送せず、
`continuation`と`requiredMinimumBytes`以上の`byte_budget`だけで同じstate bindingから回復する。item自体はbudget内だが
先行item後の残budgetへ収まらない場合だけ、現在pageを`hasMore: true`と通常continuation付きで閉じる。
したがって候補が少なくても、freshness pathやproviderが多いprimary responseを無制限に膨張させない。

analyze scope streamのglobal kind順は`input_path → input_symbol → required_provider → freshness_binding → provider_report →
coverage_gap → candidate → evidence → candidate_evidence`で固定する。文字列比較はUnicode localeでなくunsigned UTF-8
byte lexicographic order、nullはnon-nullより後、整数は昇順とする。identity tupleは各UTF-8 fieldを
`decimal-byte-length ":" raw-bytes`で連結し、nullを`-:`として表す。subject canonical identityは次のclosed formだけである。

tuple atomはstring/enum/digestをそのUTF-8 bytes、整数を符号なしbase-10 ASCII（leading zeroなし）、booleanを`0`／`1`
へしてからlength-prefixする。SHA-256は64文字lowercase hexに正規化する。pathはworkspace runtimeがroot identityの
case規則、symlink containment、`.`／`..`除去、separator `/`で確定したroot-relative UTF-8 bytesを使い、追加のUnicode
normalizationは行わない。異なるkindのidentity衝突を避けるためtuple先頭へkind名を必ず置く。

- `path`／`resource`: normalized root-relative path。
- `symbol`: path、start offset、end offset、name、stable IDのidentity tuple。
- `test`／`target`: ecosystem ID、project profile identity、manifest path、declared IDのidentity tuple。
- `module`／`package`: ecosystem ID、manifest path、declared IDのidentity tuple。

各kind内のsort keyは次で固定する。

- `input_path`: path、`expected_absent`、content SHA-256。
- `input_symbol`: symbol canonical identity、content SHA-256。
- `required_provider`: provider ID。
- `freshness_binding`: binding role（`input`、`analysis`の順）、path、content SHA-256。
- `provider_report`: provider ID、kind、version、status。
- `coverage_gap`: category順、reason code、provider ID、subject canonical identity。category順は
  `references → dependencies → related_tests → build_targets`。
- `candidate`: category順、subject kind順、subject canonical identity、candidate ID。subject kind順は
  `path → symbol → resource → module → package → test → target`。
- `evidence`: provider ID、起点input canonical identity、候補subject canonical identity、relation順、locator identity、
  `evidenceStrength`順、summary bytes、evidence ID。relation順は
  `declared_dependency → contains_source → contains_test → semantic_reference → lexical_reference → naming_heuristic`、strength順は
  `heuristic → lexical_match → semantic_match → declared_edge`。
- `candidate_evidence`: candidate ID、evidence ID。

candidate IDはcategoryとsubject canonical identity、evidence IDはprovider ID、起点identity、候補identity、relation、
locator identity、`evidenceStrength`、summaryのexact UTF-8 bytesを並べたlength-prefixed bytesへSHA-256を掛けた
lowercase hexとする。locator identityはfile evidenceなら
path、content SHA-256、start/end offset、manifest evidenceならmanifest path、content SHA-256、edge IDのtupleである。
起点input canonical identityは`input_path`または`input_symbol`をkind先頭にした上記tupleそのものとする。同一sort keyの
tieはcanonical JSONL item bytesで解消し、完全一致itemは一件へdeduplicateする。providerの列挙順やhash map iterationへ
依存しない。同じevidence IDが異なるcanonical identityまたはitem bytesへ対応した場合は、SHA衝突を含め
`EVIDENCE_ID_COLLISION`でrequest全体を失敗させ、一方を選択・上書き・併合しない。

canonical requestと完全item streamを保持する`expires_at`付きartifact handle、完全bytesのSHA-256を必ず発行し、
advertised retention中は削除しない。error resultを含め、budget外の`providers`、`coverageGaps`、freshness path一覧、
evidence ID一覧を重複して返さない。silent truncationは禁止する。

`change_impact`はcandidate-onlyであり、command、test、build、lintを起動せず、workspaceを変更しない。
focused check候補との対応はACE-033の契約が行い、実行はcallerがcheck IDを明示した`run_check`だけが行う。
`related_tests`や`build_targets`を返した事実を、選択済み、実行済み、完全な影響集合として表示しない。

provider crash、malformed output、artifact発行失敗はtyped errorまたは明示provider failureにし、前回結果、basename
類似、全test、全targetへfallbackしない。provider processはshell文字列として評価せず、executable URL、arguments、
working directoryを分離する。

## Verification contract

- `multi-file-change` fixtureで二つのchanged pathからreference、manifest dependency、related test、build targetを返し、
  全candidateが入力SHA、provider、evidenceへ逆引きできることを確認する。
- 同名symbolを複数fileへ置き、path・SHA・rangeなしの曖昧入力を拒否し、stable IDなしではlexical candidateを
  semantic referenceへ昇格しないことを確認する。
- request直後、provider解析中、continuation page間にsourceまたはmanifestを変更し、`CONTENT_CHANGED`となって
  stale候補を一件も返さないことを確認する。
- stale index、欠損toolchain、未対応ecosystemをそれぞれ`stale`、`unavailable`、`unsupported`で固定し、
  optional時は`coverage: partial`、required時は`REQUIRED_PROVIDER_NOT_FRESH`になることを確認する。
- candidate 0件、provider全滅、探索上限到達を区別し、「影響なし」や全testへのfallbackにならないことを確認する。
- provider順を変えてもcandidate/evidence順とdigestが一致し、重複候補では全provenanceが保持されることを確認する。
- byte budget N/N+1、item境界、continuation改ざん、retention失効を固定し、全page連結が完全artifactと一致する。
- 先頭item自体がbudgetを1 byte超えるfixtureで`BYTE_BUDGET_TOO_SMALL`と正確な`requiredMinimumBytes`を検証し、
  errorのrecovery continuationと増加budgetだけを送って同じitemから開始する。continuationへのsemantic field併記と
  budget縮小を`INVALID_CONTINUATION_REQUEST`にする。先行item後の残budgetだけが1 byte不足するfixtureではpageを正常に閉じ、
  continuationの次page先頭が同じitemになることを確認する。
- request 4,194,304 bytes、各件数、各文字列、item 16,384 bytes、page 4,096件の境界値と+1を固定する。
- freshness bindingだけでbudgetを超えるfixture、provider/gapだけで超えるfixtureを固定し、primary responseの全fieldが
  schema上限内であること、全page連結でpath/SHA/provider/gapを欠落なく復元できることを確認する。
- 凍結benchmark v1のdigestとrequestを不変に保ち、統合v2 fixtureがcursorなし、string path、`providers`を拒否して、
  必須`operation: analyze`、`workspace_cursor`、path/SHA object、`required_providers`だけを受理することを確認する。
- operation欠損／enum外を`INVALID_OPERATION`、ACE-033契約確定前の`operation: recommend`を`NOT_READY`に固定し、
  analyze itemやlegacy projection fieldが一件も生成されないことを確認する。ACE-033契約確定後は同じpre-release schemaの
  recommend closed set fixtureを公開gateに必須化する。
- benchmark adapter traceがexact v1 request、trusted setup digest、exact v2 request、raw v2 page/artifact、v1 projectionを
  順に保持し、oracle/expected/agent reportへのreadをspyで0件にする。
- direct-dependent、unresolved-edge、depfile-impact、missing-evidenceのraw v2 item fixtureから`impactedPaths`、
  `provenance`、`unknowns`、`silentCompletenessClaims`のexact v1 projectionを固定する。未知edge、欠損page、artifact
  digest不一致は`BENCHMARK_PROJECTION_INVALID`となり補完されないことを確認する。
- analyze projectionが`schemaVersion: aishell.change-impact.v1`と4 fieldだけ、recommend projectionが同じ
  `schemaVersion`と`recommendedChecks`／`executionRequiresOptIn`だけを返すことをexact key setで確認する。
  `focused-pipeline-recommend-only`／`focused-pipeline-explicit-run`では`test_path`だけがprojectされ、label/check IDからの
  推測、scope間field混入、unknown action、`executionPolicy`欠損を`BENCHMARK_PROJECTION_INVALID`にする。
- locatorまで同一でstrengthまたはsummaryだけが異なるevidenceが別IDになることを確認する。digest functionをfixtureで
  衝突させ、異なるcanonical evidenceが同じIDなら`EVIDENCE_ID_COLLISION`となり候補を返さないことを確認する。
- provider投入順を全順列化してもglobal kind順、kind内sort、candidate/evidence ID、全artifact SHAが一致する。
- spy executorで`change_impact`中のtest/build起動が0件であることを確認する。callerが明示したcheckだけを
  `run_check`が実行する境界はACE-033/034のfocused fixtureで固定する。
- 既存default 7／full 25 tool、workspace cursor、search/read結果を非回帰とし、expanded flag時だけ
  `change_impact`を既定順で公開する。

## Consequences

ACE-034は`AIShellCore`へ候補graphとprovider seamを実装し、`AIShellMCP`にはschema変換だけを置く。
Phase 3の価値は完全影響解析の宣言ではなく、OS現在状態へ束縛した候補と根拠でAI hostの再探索を減らすことにある。
providerを追加する場合も、freshness判定をproviderへ委譲せず、OS SHAへ束縛できない結果は採用しない。

Phase 6のablationではSourceKit semantic referenceとSwiftPM build manifestが候補categoryを増やす一方、
現行serviceにはecosystem／入力別にproviderを選ぶrouterがないことを確認した。この状態で全default requestへ追加すると、
対象外projectでもworker試行とcoverage gapが増える。したがってACE-064時点のdefault routingは
`aishell.filesystem-impact`と`static-import`だけを維持し、`sourcekit`、`swiftpm-build-manifest`、`depfile`は
明示注入可能なproviderとして保持する。default昇格は、選択routerと実worker込みbenchmarkでtotal token／wallの改善を
確認した場合だけ行う。
