# AIShell開発利用adoption監査

> 本書は調査・実測時点の記録。フォルダ登録と許可範囲に関する現行仕様は[ADR 0030](../docs/adr/0030-folder-registration-removal.md)を参照する。現在の操作手順はREADMEに従う。

- 調査日: 2026-08-04
- 対象期間: 2026-07-19〜2026-08-04
- 対象: このMacのThroughlineに捕捉されたCodex／Claude session、`~/Developer`配下のgit repository、対話host設定、AIShell runtime
- 確度: 中〜高（session捕捉範囲には依存するが、設定・失敗・公開schema・同一query比較は実機で再現）

## 結論

AIShellが日常開発でほぼ使われなかった主因は一つではない。Claudeではtool catalog全体がschema検証で拒否され、Aiterm managed Claudeでは設定隔離がuser scope MCP登録まで落とし、Codexでは高密度4 toolを欠くdefault登録へdriftしていた。日常の対象repositoryの多くも許可root外だった。さらに全project共通指示はaiterm PTYをshell入口として強く指定する一方、AIShellの使い分けを記載していなかった。product側にもcursorなし`search_context`の既定矛盾、file scope拒否、実workspaceでの前処理暴走があった。

一方、狭い単発検索ではnative `rg`がAIShellより明確に小さく速い。したがってadoptionを「全commandをAIShellへ置換する率」として最大化してはならない。AIShellを優先するのは、OS状態の保持が再scan・再読・再実行を減らす反復／複数file観測、大出力check、process lifecycle、cursor束縛multi-file changeだけである。

## 観測

### Session tool利用

- Codex: unique tool call 115,531件のうち、AIShell wrapper callは257件。254件は7月19日のAIShell自己開発／benchmarkで、以後の日常課題は3件だけだった。
- その日常3件は`bingo` 2件、`RootSitePromotion` 1件で、すべて`OUTSIDE_ALLOWED_ROOT`により失敗した。
- Claude: 修正前の実AIShell callは0件。`expanded-v1`のunion input/output schemaにtop-level `type: object`がなく、Claude Codeがcatalog全体を拒否していた。
- Aiterm managed Claude: schema修正後も`--setting-sources ""`によるhook隔離が`~/.claude.json`のuser scope `mcpServers`まで不可視にし、fresh sessionではAIShellが0件だった。Aiterm 0.21.4がuser scope MCPだけをowner-only launch configへsnapshotし、fresh ClaudeでAIShell 11 tool、`runtime_status`、単一file scopeの`search_context`成功を確認した。
- 代替入口はCodexで`exec_command` 22,206件、aiterm read/send 約14,889/13,163件、`apply_patch` 6,976件。ClaudeではBash 20,632件、Read 3,695件、Edit 3,226件、aiterm read/send 約2,010件だった。

集計は同一tool callの再収録をcall identityでdeduplicateした。したがって表示行数ではなく呼出し単位の比較である。

### Project discoveryと許可scope

- `~/Developer`配下にgit repositoryは38件あった。
- 監査時の手動許可rootは11件で、残り27 repositoryは親rootにも含まれなかった。
- project-local `AGENTS.md`／`CLAUDE.md` 84件のうちAIShellを記載したのはAIShell自身の1件だけで、aitermは8件に記載されていた。
- Codexの実登録は絶対pathの`aishell-mcp`、environmentなしでdefault 7 toolだった。dotagents正典はbare commandと`AISHELL_CAPABILITY_SET=expanded-v1`による11 toolを要求していたが、既存`verify-install`はbinary存在しか検査していなかった。

### 同一queryのcost

`dotagents`で`AISHELL_CAPABILITY_SET`をREADME/docs/bin/testsから検索し、同じ16 matchを得たwarm実測:

| 経路 | wall | 返却規模 |
|---|---:|---:|
| native `rg -n -F` | 0.02秒 | 4,150 bytes |
| AIShell `workspace_snapshot` | 0.887秒 | structured 2,482 bytes |
| AIShell `search_context` | 1.424秒 | structured 13,645 bytes（service returned 18,977 bytes） |

この比較は単発固定検索だけのcharacterizationであり、反復時のdelta再利用や完全artifact保持の効果量を否定しない。逆に、このtask classまでAIShellへ強制するとnorth starのwall/model tokenを悪化させる可能性が高い。

## 原因分類

1. **利用不能**: Claude catalog schema拒否。
2. **scope不一致**: 38 repository中27件が許可root外。実日常call 3件は全滅。
3. **host登録drift**: Codexがdefault 7 toolで、高密度の`change_impact`、`apply_change_set`、`run_observe`、`workspace_wait`を発見できない。
4. **公開request既定の矛盾**: `ranking`と`changed_since_cursor`はschema上optionalなのに、省略rankingが`changed`を含みcursor必須errorになった。
5. **process timeoutの未完了**: SourceKit-LSP子processをtimeout終了しても親がstdout pipeの書込み端を保持し、readerがEOFを受け取れずrequestが終わらなかった。
6. **実workspaceでのcontext前処理暴走**: 0.4.9公開後のfresh host smokeで、省略検索が数分CPUを占有した。sampleでは全entryのsort comparatorが比較ごとに相対pathを`URL(fileURLWithPath:)`へ変換し、`getcwd`／`lstat`を反復していた。
7. **routing正典の空白**: aiterm、native search/edit、Latticeの入口は全体指示にあるが、AIShellを先に使うtask classがなかった。
8. **file scopeの公開契約欠落**: `search_context.path`を「検索root」と説明しながらdirectoryだけを受理し、fresh Claudeが実在tracked `README.md`を指定すると`INVALID_PATH`になった。
9. **正しい非採用**: single-file edit、狭い一回検索、小出力command、PTYはAIShellの対象外であり、native/aiterm利用が正しい。

## 修理

- AIShell 0.4.8: Claudeが拒否したunion schemaを修正し、fresh Claude Code 2.1.221で11 tool loadと実callを確認。
- AIShell 0.4.9: cursorなし検索の既定を`tests`、cursorありを`changed, tests`へ修正。explicit `changed` without cursorは引き続きtyped error。
- AIShell 0.4.9: SourceKit-LSP launch後に親の未使用pipe端を閉じ、子のexit/timeout時にEOFでblocking readを解放。termination観測後の重複`waitUntilExit()`も除去し、全suite内で再現した終了待ちdeadlockを解消。
- AIShell 0.4.10: context候補のpriorityをentryごとに一度だけ文字列から計算してdecorate-sortし、relative pathごとのfilesystem解決とsort比較回数分の再計算を除去。cursor-free lexical searchでは有効checkpoint復元後のfull filesystem scanと未使用indexed-file projectionを省き、Git profile discoveryはtracked＋non-ignored untracked manifestだけを列挙する。198,478 entry／74 MB checkpointの同一release queryは約20秒の全scan段階から5.94秒まで短縮。全payload SHA・schema・entry invariant検証は維持。
- AIShell 0.4.11: `search_context`がdirectoryに加えて単一regular fileをscopeとして受理する。lexical workerはそのfileだけを直接検索し、globはattested indexからexact fileだけを許して、親directoryやsiblingへ暗黙に広げない。commit `eb7e36ff6ae3`のCI `30874932377`はSwift 6.1.2でfull test／app package／npm payloadを完走。npm `latest`、global package、app bundleはいずれも0.4.11。fresh managed Claudeは11 toolを発見し、`runtime_status`成功、`search_context(query:"AIShell", path:"README.md", byte_budget:1200)`成功（7件、1,132 bytes）を返した。
- Aiterm 0.21.4: managed Claudeの通常hook／plugin／permission／project-local MCP隔離を維持しつつ、user scope `mcpServers`だけを0600のlaunch snapshotで継承する。定義やcredentialはargv／metadata／logへ展開しない。
- runtime: 管理UIから`/Users/kite/Developer`を許可rootへ追加し、以前失敗した`bingo`のsnapshot成功を確認。
- host config: Claude/Codex両方をbare `aishell-mcp`＋`expanded-v1`へ統一。
- dotagents: READMEへ両hostの登録を追加し、`verify-install`がscope/enabled/command/environment/connectionを検査するよう変更。
- 全体正典: AIShell優先を反復・複数file・大出力・lifecycle・cursor束縛変更へ限定し、単発`rg`／小出力／single-fileはnative/aitermと明記。

## 次の製品gate

本監査は壊れた入口の修理であり、一般化された削減率の証明ではない。入口修理後に、同一model snapshot・reasoning・fixture・prompt・sandboxで30 task以上のproduct gateを実行し、失敗試行を含む`tokens per solved task`、成功率、wall、tool adoptionを比較する。それまでは7月19日の小規模fixture効果量を全projectへ一般化しない。
