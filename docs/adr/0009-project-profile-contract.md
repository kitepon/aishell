# ADR 0009: project profile契約

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: Accepted
- Date: 2026-07-21
- Lattice task: `ACE-021`
- Control: `aishell-capability-expansion-20260721`

## Context

現行`workspace_snapshot`は`Package.swift`、`package.json`等のpath配列とtest候補を返すだけで、どのmanifestが
一つのprojectを構成するか、target、toolchain、build／test／lint入口、各情報の根拠とfreshnessを持たない。
AI hostはsnapshotのたびにmanifestを再読し、project境界を推測し、同じtoolchain probeを再実行する必要がある。
また、単純なbasename探索ではmonorepoのmember、fixture内の入れ子manifest、異なるecosystemの同居を区別できない。

project profileはworkspace indexから導出して保持する高密度contextであり、filesystemやpackage managerの代替正本ではない。
Phase 2ではSwiftPMとnpmを完全対応providerとし、それ以外を対応済みに見せず、同じ公開schemaでpartial又は
unsupportedを明示する。

## Decision

### 1. `workspace_snapshot`への統合

`workspace_snapshot` v2へ省略可能な`project_profile` requestを追加し、resultへ
`projectProfiles: [aishell.project-profile.v1]`と`projectProfileSummary`を返す。既定は
`project_profile: { mode: "auto" }`であり、request pathを所有するprofileと、そのprofileから明示参照される
workspace memberをcatalogからprojectする。`mode: "all"`はeffective allowed root内の全profile、`mode: "none"`は
profile projectionを省略する。`none`でもcatalogのOS変更追跡を止めず、次回に全manifestを再scanさせない。
`project_ids`を指定した場合はそのstable IDだけを返し、未知IDは`PROJECT_NOT_FOUND`とする。

これは新しい公開toolを追加しない。既存`manifests`、`testCandidates`、full／delta、entry／context budget、Git status、
cursor errorは互換期間中も維持する。profileを追加するためにdefault 9／control込み11／full 29 toolを削減しない。
v1互換resultでは従来fieldだけを返せるが、内部profile cacheとworkspace freshnessの判定は共通にする。

`project_profile.byte_budget`は1,024〜262,144 bytes、既定65,536、`profile_limit`は1〜1,000、既定100とする。
各profileのsummaryと、modeにより選ばれた本文を一つのprojection recordにし、各recordのRFC 8785 JCS bytesへLF 1 byteを
付けたJSONL item streamへ順に置く。
`auto`でauxiliary本文を省略するrecordはsummaryと`projection: summary_only`を持つ。この共有budgetと件数上限を
一record単位で消費し、summaryと対応本文を別pageへ分離せず、recordを途中で切らない。request budget以下の次recordが
page残量へ収まらない時はそこでpageを閉じ、`projectProfileHasMore=true`、省略件数と
`projectProfileContinuation`を返す。continuationはその未返却recordを次pageの先頭にし、root identity、workspace
generation／sequence、request、
profile binding digest、次offsetへ束縛する。改ざんは`INVALID_CONTINUATION`、状態変化は`CONTENT_CHANGED`、
retention失効は`CURSOR_EXPIRED`とし、先頭からの暗黙再取得へfallbackしない。budget外のaggregate summaryは
`totalProfiles`、status別件数、`returnedProfiles`、`omittedProfiles`、`returnedBytes`、`omittedBytes`だけを持ち、
profile別情報を迂回して載せない。全page連結で全profileとsummaryをlosslessに回収できることを必須にし、単なる
先頭N件へのsilent truncationを許さない。

単一の完全projection recordがrequestの`byte_budget`へ収まらない場合は、その位置に
`projection: artifact_only`、`projectId`、完全recordのbyte lengthとSHA-256、`expires_at`付きartifact handleを持つ
`aishell.project-profile-oversize.v1` descriptorを返す。artifactは完全recordのRFC 8785 JCS bytesをadvertised retention中
losslessに保持する。descriptorのJCS bytesは最大1,023 bytesになるようfield lengthとhandle形式を固定し、LFを含めても
最小budget内へ必ず収める。特に完全recordが最大budget 262,144 bytesを超えても同じ規則を適用する。
このdescriptorを一件返したpageは元recordを消費済みとしてcontinuation offsetを次recordへ進める。同じoversize recordを
空pageと同じcursorで返し続けず、後続recordがあれば`hasMore=true`、なければfalseにする。artifact発行又はbounded descriptor
生成に失敗した場合は`ARTIFACT_WRITE_FAILED`又は`PROFILE_DESCRIPTOR_OVERFLOW`でrequest全体を失敗させ、silent omissionや
budget超過resultを返さない。

### 2. projectの発見とmulti-project境界

profile catalogのownerはsnapshotのrequest pathや一時的なscan rootではなく、project rootを包含する
effective allowed rootである。allowed rootが重複する場合はcanonical pathのcomponent数が最大のroot、同数なら
canonical pathのUTF-8 byte order、同pathなら`device:inode` identityのbyte orderで先頭のrootをownerにする。
symlink spellingやrequest pathの深さでownerを変えない。catalog keyはownerのcanonical path、`device:inode` identity、
allowed-root policy digestを格納したRFC 8785 JCS objectのSHA-256であり、snapshotはこのcatalogからrequestに必要な
profileだけをprojectする。

profileは`projectId`、owner rootからの`projectRoot`、`ecosystem`、`manifestSet`で識別する。ID descriptor、binding、
profile digest、pagination recordのcanonicalizationは例外なくRFC 8785 JSON Canonicalization Scheme（JCS）へ固定し、
独自のkey順、数値表現、escape規則を併用しない。JCS準拠serializerが生成したUTF-8 bytesだけをhash／byte budgetの入力にする。
path valueはJCSへ渡す前にfilesystemからlosslessに得たUnicode scalar列を正規化せず、`.`／`..`を解消した`/`区切り
relative pathへする。lossless UTF-8にできないpathは`PATH_ENCODING_UNSUPPORTED`とし、置換文字でIDを作らない。
`projectId`は次のdescriptorのJCS bytesをSHA-256にし、小文字hexで表す。

```json
{"ecosystem":"<closed provider ecosystem>","owner_root_identity":"<device:inode>","primary_manifest":"<owner-relative path>","project_root":"<owner-relative path>","schema":"aishell.project-id.v1"}
```

表示名、manifest本文、file inode、列挙順、provider versionの変更ではIDを変えない。project root又はprimary manifestの
rename、owner root identityの置換、ecosystem変更では新IDになる。結果順は`projectRoot`のUTF-8 byte order、ecosystem、
primary manifest pathとする。同じdirectoryに複数ecosystemがある場合は別profileとして共存させ、どちらかへ統合しない。

provider v1の発見規則は次で固定する。

| Provider | primary manifest | profile境界と関連manifest | 対応状態 |
|---|---|---|---|
| SwiftPM | `Package.swift` | 同directoryをrootとし、`Package.resolved`と`.swiftpm/configuration`配下の存在する設定を束縛する | complete |
| npm | `package.json` | 同directoryをrootとし、宣言された`workspaces`だけをmemberとして展開する。`package-lock.json`、`npm-shrinkwrap.json`を束縛する | complete |
| XcodeGen | `project.yml` | 同directoryを候補rootとし、manifest pathだけを報告する | partial |
| Cargo | `Cargo.toml` | 同directoryを候補rootとし、`Cargo.lock`を関連付ける | partial |
| Python | `pyproject.toml` | 同directoryを候補rootとする | partial |
| Go | `go.mod` | 同directoryを候補rootとし、`go.sum`を関連付ける | partial |

SwiftPM packageをnpm workspace memberの内側に置く等、明示的な入れ子projectは両方返す。npm memberはroot profileに
`memberProjectIds`として束縛すると同時に、独自`package.json`を持つmember profileとして返す。ownerを一つに潰さず、
source pathの候補ownerは最も深いproject rootを先頭にし、同じ深さでは全ecosystemを保持する。

workspace indexの除外契約（v1では`.git`、`.build`、`node_modules`）内は探索しない。さらに`fixtures`、`examples`、
`benchmarks`、`vendor`配下のmanifestは黙って本番projectへ混入させず、親manifest又はworkspace設定から明示参照された場合を
除いて`classification: auxiliary`として別profileにする。directory名だけで消去はしない。`mode: auto`ではauxiliaryを
summaryに残して本文から省略し、`mode: all`では返す。これによりbenchmark内の入れ子manifestを主projectのtargetやcheckへ
混ぜない一方、fixture自体を解析する能力は失わない。

manifestのparse失敗、workspace globのroot外escape、symlink経由のroot外member、同一memberの重複所有はtyped diagnosticを
profileへ付ける。影響profileだけを`status: invalid`又は`partial`にし、別の有効profileを消さない。ただしrequestで指定した
唯一のprofileがinvalidなら成功した空配列ではなく対応するtyped errorを返す。

### 3. profile schemaとprovenance

各profileは少なくとも次を持つ。

- `projectId`、`projectRoot`、project root identity、`displayName`、`ecosystem`、`classification`
- `status: complete | partial | unsupported | invalid`、`provider`、`providerVersion`、不足能力とdiagnostic
- primary／related manifestごとのpath、file identity、content SHA-256、role、parse status
- lockfile、workspace member、target、source／resource／test root、generated outputの宣言値
- toolchain、build／test／lint check、各fieldの`provenance`
- `binding`、`freshness`、`observedCursor`、`profileDigest`

targetは`targetId`、name、kind（executable／library／test／plugin／aggregate／unknown）、declared dependency、
source roots、resource roots、test relationを持つ。manifestに書かれた値とproviderが解決した値を混同せず、各値の
`provenance.kind`を`manifest | lockfile | toolchain_probe | workspace_index | convention`、source path、content SHA、
parser/probe versionで示す。convention由来は`confidence: heuristic`に固定し、manifest由来に昇格させない。

`targetId`は次のdescriptorのRFC 8785 JCS bytesをSHA-256にした小文字hexとする。`provider_target_key`はSwiftPMならmanifestのtarget name、
npmならpackage name又はname欠落時のmember root relative pathであり、providerは同じprofile内で一意なlossless keyを返す。

```json
{"kind":"<closed target kind>","profile_id":"<projectId>","provider_target_key":"<provider-owned stable key>","schema":"aishell.target-id.v1"}
```

targetのsource pathやdependency変更、provider version更新ではdescriptorが同じならIDを維持する。target rename、kind変更、
profile ID変更では新IDになる。providerがstable keyを作れないtargetは`targetId`を捏造せずprofileを`partial`にする。

checkはstable `checkId`、`kind: build | test | lint`、label、project／target scope、`executable`、順序付き`arguments`、
`workingDirectory`、参照environment key集合、toolchain binding、provenanceを持つ。shell文字列を生成せず、executable URLと
argumentsを分離する。manifest scriptsはscript本文を勝手にshell分解せず、npm providerなら解決済みnpm executableへ
`["run", scriptName, "--", ...]`を渡す入口として表現する。任意のscriptを既知checkへ昇格せず、SwiftPMの標準
`build`／`test`、npmの存在する`build`／`test`／`lint` scriptだけを既定候補にする。checkは候補定義であって
`workspace_snapshot`中に実行しない。

`checkId`は次のdescriptorのRFC 8785 JCS bytesをSHA-256にした小文字hexとする。`scope_id`はproject scopeなら`projectId`、target scopeなら
`targetId`、`provider_check_key`はSwiftPM標準action名又はnpm script nameである。

```json
{"kind":"<build|test|lint>","profile_id":"<projectId>","provider_check_key":"<provider-owned stable key>","schema":"aishell.check-id.v1","scope_id":"<projectId|targetId>"}
```

script本文、resolved executable、arguments、environment、toolchain、provider versionの変更はcheck bindingとprofile digestを
変えるが、logical entrypoint descriptorが同じならIDを維持する。script rename、kind／scope変更、profile／target ID変更では
新IDになる。ID descriptor又はcanonicalizationを変える時はschemaを上げ、旧IDを新規則で黙って再解釈しない。

npm projectがcheckをfreshness cache対象へ明示昇格する時だけ、`package.json`に次のclosed宣言を置ける。
通常の`scripts`は従来どおり`npm run <kind> --`として実行可能だが、shell scriptのeffectとrelevant input closureを
証明できないため`ineligible`のままとする。AIShellはscript本文からargvや入力を推測しない。

```json
{
  "aishell": {
    "schemaVersion": "aishell.package-profile.v1",
    "checks": {
      "test": {
        "executable": "node",
        "arguments": ["check.mjs"],
        "environmentKeys": [],
        "includedRoots": ["check.mjs", "src/value.mjs"],
        "trackedPaths": [],
        "effects": "project_root_closed"
      }
    }
  }
}
```

v1は`build | test | lint`とdirect `node`だけを受理する。`npm`はscript shellとtransitive executableを閉じられないため
明示宣言でも拒否する。各objectは追加fieldを拒否し、argumentsのNULを拒否する。`environmentKeys`はcheckが結果へ
影響すると宣言した環境変数名のclosed集合であり、値をprofile bindingとrun cache bindingの両方へ含める。未設定と
空文字列は別状態として束縛する。input pathはNFCの
project-relative canonical path、重複なし、`..`／absolute／backslashなしでなければならない。`includedRoots`は
1件以上を必須とし、`trackedPaths`との重複を拒否する。`effects`は`project_root_closed`だけであり、宣言全体が
正しく検証できたcheckだけを`complete`へ昇格する。未知schema、未知kind、未解決executable、open effect、不正pathは
manifest errorとしてfail-closedにし、通常scriptや推測contractへfallbackしない。

SwiftPM providerは`Package.swift`の静的parseだけで完全を主張しない。許可された`swift package dump-package`を
shellなしで起動し、target graphを取得する。npm providerは`package.json`とlockfile/workspace宣言からprofileを作り、
依存installやlifecycle scriptを実行しない。probe stdout/stderrの完全bytesは`expires_at`付きartifactとして保持し、
profileにはexit status、artifact SHA-256、handleを付ける。providerが必要な完全解析を実行できない場合は
`partial`又はtyped errorであり、basename列挙へsilent fallbackしない。

### 4. toolchain binding

toolchainはlogical name、resolved executable URL、executable file identityとcontent SHA-256、version probeの順序付きargv、
exit status、normalized version、raw evidence artifact SHA／handleを持つ。解決はAIShell process policy下の明示候補だけを使い、
shell、`env`、`xcrun`文字列評価へ退行しない。SwiftPMは実際にpackage解析とcheckで使う`swift`、npmは実際に使う
`node`と`npm`を同じbindingへ固定する。PATHの文字列だけ、version文字列だけをidentityにしない。

実行可能fileがroot外にあること自体は通常のtoolchainであり、allowed-root外source読取りの許可には使わない。
executable解決不能、probe失敗、versionをlosslessに保持できない場合は`TOOLCHAIN_UNAVAILABLE`又は
`TOOLCHAIN_PROBE_FAILED`とし、古いtoolchain情報をfreshとして返さない。unsupported providerではprobe自体を行わず、
`status: unsupported`と未対応能力を返す。

### 5. binding、freshness、失効

`binding`は次をRFC 8785 JCS objectへ格納し、そのJCS bytesのSHA-256へ束縛する。

1. workspace root identity、exclusion digest、generation、profile観測時cursor。
2. project root identity、provider名／version、primary／related manifestとlockfileのidentity・content SHA。
3. workspace member展開結果、target/check定義、参照されたlocal config／workflow／script fileのidentity・content SHA。
4. 各toolchainのresolved executable identity・content SHA、version evidence SHA、解析に影響するenvironment key/value digest。

environmentはproviderが宣言したkeyだけを値のSHA-256として束縛し、secret値をprofileへ返さない。時刻、TTL、cwdの偶然の
値をfreshness根拠にしない。`profileDigest`は表示用時刻、artifact expiry、cursor sequenceを除くprofile意味内容の
RFC 8785 JCS bytesのSHA-256とする。

workspace deltaでは変更pathをprofileのbinding inputとownership indexへ照合し、影響profileだけを再解析する。
manifest、lockfile、参照config、toolchain executable、binding対象environment、project root identity、provider versionの変更は
必ず失効する。source本文だけの変更はtarget/check構造を失効させず、新しい`observedCursor`へ再束縛する。ただしsourceの
create/delete/renameがsource root又はtest relationを変える場合は影響profileを再導出する。無関係なREADME変更や別projectの
変更で全profileを再probeしない。

provider version変更は該当providerの全profileを再parse／再probeし、bindingと`profileDigest`を更新する。一方で
`aishell.project-id.v1`、`target-id.v1`、`check-id.v1` descriptorが同一なら各IDを維持する。provider更新でstable keyの意味を
変更する場合はprovider側で新keyを返して新IDにするかID schemaを上げ、同じIDへ別target/checkを割り当てない。

cache hitは現在workspace cursorまでのdeltaを検査し、全binding input不変を証明した時だけ`freshness: fresh_cached`とする。
再解析結果は`fresh_computed`、未検証のcheckpoint由来は返さず`RESCAN_REQUIRED`、観測中変更は`CONTENT_CHANGED`とする。
event gap、期限切れcursor、checkpoint破損をTTLや前回profileで埋めない。失効理由は`invalidationReasons`へpath、旧新SHA、
toolchain identity変更等を機械判定可能に記録する。

### 6. partialとerror境界

`partial`は「認識済みproviderだが一部能力を提供できない」場合だけで、`missingCapabilities`と各理由を必須にする。
`unsupported`はmanifestを発見したがproviderが解析を所有しない場合であり、manifest path以外のtarget/checkを推測しない。
一つのworkspaceにcomplete、partial、unsupported profileが混在することは正常である。

一方、次は成功resultへ丸めずtyped error又はprofile-local invalid diagnosticにする。

- 指定profileのmanifest decode失敗: `PROJECT_MANIFEST_INVALID`
- workspace memberがallowed root外又はsymlink escape: `PROJECT_MEMBER_OUTSIDE_ALLOWED_ROOT`
- provider/probe process失敗: `PROJECT_PROVIDER_FAILED`／`TOOLCHAIN_PROBE_FAILED`
- 観測transaction中のbinding input変更: `CONTENT_CHANGED`
- profile continuationとroot/generation/binding不一致: `INVALID_CONTINUATION`／`CURSOR_EXPIRED`
- 完全証拠artifactの発行失敗: `ARTIFACT_WRITE_FAILED`

複数profileの`auto`／`all` requestではprofile-local invalidをsummaryと本文に残し、正常profileも返す。ただしworkspace cursorの
freshnessを証明できないglobal error、continuation不整合、artifact発行失敗はpartial resultを返さずrequest全体を失敗させる。
SwiftPM解析失敗時にbasename manifest配列だけをcomplete profileとして返す、npm toolchain不在時に別package managerを試す、
古いcacheを時刻だけで採用する、といったsilent fallbackは禁止する。

## Verification contract

- contract-focused fixtureは同一workspaceにSwiftPM root、npm workspace rootとmember、同directory異ecosystem、
  `benchmarks`内のauxiliary manifestを置き、project数、stable ID、境界、member relation、決定的順序を固定する。
- SwiftPMはlibrary／executable／test target、product dependency、標準build/test checkと`dump-package` evidenceを検証する。
  npmはworkspace glob、lockfile、build/test/lint script、member check、依存install／script非実行を検証する。
- `project.yml`、Cargo、Python、Goはmanifest発見を保ちながら`partial`と不足能力を返し、架空target/checkを返さない。
- manifest、lockfile、参照script、toolchain executable、environment bindingを一つずつ変更し、対象profileだけの
  `profileDigest`と失効理由が変わることを確認する。別projectとREADMEだけの変更ではtoolchain probe countを増やさない。
- source create/delete/renameはownershipとtest relationを再導出し、source本文だけの変更は構造cacheを再利用して新cursorへ
  束縛する。event gap、観測中変更、root置換、corrupt checkpointは古いprofileを返さずtyped errorになる。
- invalid manifest、root外member、missing toolchain、probe nonzero、artifact失敗、unsupported providerを個別に固定する。
- byte budget 0件境界、N/N+1、continuation改ざん、page間変更、全page連結が単発`all`結果と一致することを検証する。
  262,144 bytesを超える単一profileはbudget内のoversize descriptorと完全artifactへ置換され、continuationが必ず
  次recordへ進み、artifact JCS bytesのSHA-256が独立再計算値と一致することを固定する。
- overlapping allowed rootと同一root identity tieを固定し、request path、symlink spelling、snapshot対象directoryを変えても
  catalog ownerとIDが変わらないことを検証する。project／manifest／target／check renameとprovider version更新について、
  上記descriptorからIDを独立再計算し、変更／維持規則を固定する。
- 既存`workspace_snapshot` v1のmanifest/test path、full/delta cursor、embedded context、Git statusとdefault/full tool catalogを
  非回帰にする。
- 凍結済み代表benchmark v1のfixture、prompt、oracle、集計式、arm入力は変更しない。
- ACE-023の統合実装開始前に、Lattice DAG上のimplementation predecessorとなる専用freeze taskでbenchmark v2を固定する。
  v2のproject-profile projection fixtureは、同一effective root内のSwiftPM、npm workspace/member、同directory異ecosystem、
  auxiliary、partial provider、oversize profileを含む。oracleはowner catalog identity、project／target／check ID、profile順、
  target/check provenance、toolchain binding、freshness、影響profileだけのinvalidation、budget／continuation／artifact連結を
  exact一致で検証する。prompt、model snapshot、reasoning、tool schema、sandbox、fixture bytes、provider version、token／call／
  wall-time集計式を実装前にhash固定し、native/current-AIShell/candidate armで成功課題あたりのprovider報告token、失敗試行、
  tool call、wall timeを比較する。このfreeze taskがacceptedになるまでACE-023をdispatchしない。

focused verificationはACE-023で`ProjectProfileServiceTests`、`WorkspaceSnapshotProjectProfileTests`、
MCP v1/v2 schema fixtureだけを変更中に回す。Phase 2 gateで関連workspace／MCP suiteを一度確認し、docsだけの本ADRでは
Swift testを実行しない。

## Consequences

effective allowed root catalogはGit diff、project profile、search priority、後続impact/checkが共有するroot identityと
ownershipを一度だけ決めるcommon seamである。Lattice planを実装前にrecompileし、このseamを所有する単独taskと、
benchmark v2 freeze taskをACE-023及び後続consumerのdependencyへ追加する。各consumerがsnapshot pathから別catalogを作る
並行実装を開始しない。owner境界の変更はcommon seam taskだけが行い、profile providerは確定owner key配下のmanifest／target／
check catalogだけを所有する。

ACE-023は`AIShellCore`へ`ProjectProfileService`とprovider／binding cacheを置き、common effective-root catalogと
`WorkspaceStateRuntime`のentry、cursor、deltaを入力として使う。`AIShellMCP`はrequest/result変換だけを所有し、manifest解析や
toolchain probeをhandlerへ埋め込まない。
ACE-030のrun cacheとACE-033のfocused checkは、このADRのtoolchain bindingとcheck provenanceを参照するが、profile自体は
process結果のfreshnessやcheck実行を所有しない。

ACE-023のcutoverは、ACE-020／021／022の全F契約を統合したv2 surfaceの一transactionで
`workspace_snapshot` profile request/result projectionを公開する時にだけ行う。Phase 1のwarm restoreと明示full refreshを
別々のprofile生成入口として増やさず、catalogのrestore、
OS delta照合、影響profile再解析、snapshot projectionを`ProjectProfileService`の同じ状態機械へ統合する。既存の
manifest path helperをprofile生成の自己実現的なwarm／refresh経路として残さず、v1 `manifests` projectionも同じcatalogから
生成する。cutover前にv2 profile fieldだけを部分公開したり、warm時だけ旧basename探索へfallbackしたりしない。

完全対応providerはSwiftPMとnpmから始めるが、他ecosystemのmanifest発見を削除しない。追加providerは同じstatus、binding、
provenance、typed error、focused verificationを満たした時だけ`complete`へ昇格する。
