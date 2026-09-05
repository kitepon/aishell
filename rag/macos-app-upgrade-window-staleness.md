# 起動中のmacOS appをupgradeで差し替えると無言で壊れる

> 本書は調査・実測時点の記録。フォルダ登録と許可範囲に関する現行仕様は[ADR 0030](../docs/adr/0030-folder-registration-removal.md)を参照する。管理アプリのフォルダ選択UIも廃止済みで、現在の操作手順はREADMEに従う。

- 出典: 自前実測（2026-07-25、AIShell 0.4.2窓 → 0.4.3 install）。npm側の仕様は [[raw/npm-publishing-2026]]
- 検証日: 2026-07-25
- 確度: 高（実機で発生・隔離環境で再現・修正後の挙動も実測）

## 何が起きるか

npm globalで配布した `.app` を**窓を開いたままupgradeすると、その窓は壊れるのにerrorが出ない**。

- UIは描画され続ける。buttonのhoverもclickも効く
- `runtime.json` への書き込みも成功する（`RuntimeStore` 経路は生きている）
- しかし `NSOpenPanel` / `NSSavePanel` だけが開かない。errorもlogも出ない
- `NSWorkspace.openApplication` 系も同様に失敗しうる

ユーザーから見えるのは「rootを追加ボタンが効かない」だけで、原因を示す情報はUI上に一切ない。

## 原因

npmはglobal packageを更新する時、既存directoryを同じ親の下の `.<name>-XXXXXXXX` へrenameし、
新版を本来のpathへ展開してから退避分を削除する。起動中のprocessはunlinkされたinodeを掴んで
動き続けるため、**processは生きているがbundle pathは実在しない**。macOSのbundle依存API（panel、
LaunchServices経由のapp起動）はbundle実体の解決に失敗し、黙って何もしない。

実測値:

```
lsof -p 33396 | grep MacOS/
→ /opt/homebrew/lib/node_modules/@quolu/.aishell-N2ismJiF/dist/AIShell.app/Contents/MacOS/AIShell
   （このdirectoryは当日11:22の0.4.3 installで削除済み）
```

`ps -axo comm=` もrenameを追うため、退避名を指す実行pathが確認の決め手になる。
`runtime.json` のmtimeが窓の起動より古いことが「追加操作が1度も永続化されていない」証拠になった。

Homebrew caskや手動置換でも、起動中に `.app` を差し替えれば同じ壊れ方をする。npm固有ではない。

## 検知の設計

pathの存在確認だけでは足りない。**同じpathへ別実体が入るin-place置換を見逃す**ため、実体で見る。

| 状態 | 判定 | 復帰手段 |
| --- | --- | --- |
| intact | 起動時と同じidentity | なし |
| 置換 | 同じpathに別実体（device/inode/size/mtimeの差） | そのpathを開き直して自分を終了 |
| 消滅 | pathごと無い | 同じpathからは起動できない。手動で開き直す |
| 判定不能 | 起動時identityが取れなかった | intactへ丸めない |

AIShellでは `AIShellCore/InstallationIntegrity` が判定だけを所有し、1秒pollのrefreshで再評価して
banner表示に載せる（0.4.4）。「判定不能」をintactと同一視しないのは、異常なしと言い換えないため。

**install側での前倒し警告は使えない。** npm 11.17.0はglobal installでも自package自身のinstall script
を既定でblockする（`npm warn allow-scripts` が出るだけ）。0.4.4で `postinstall` 警告を試して実測で
走らないことを確認し、0.4.5で撤回した。検知の正はapp側だけに置く（[[npm-distribution]]）。

## 実測（0.4.4の修正後）

隔離copyでの検証:

- bundle directoryをrename退避 → 1秒以内にbannerが「終了」提示で出る
- 同じpathへ別実体をcopy → bannerが「再起動」提示に変わる。押すと新実体からprocessが起動し旧processは終了
- 置換していない同一起動方式では `sample <pid>` のstackに `-[NSSavePanel runModal]` が現れpanelは正常に開く
  → 直接実行やcode signingではなくbundle実体の消失が原因、と切り分けられた

実installでの検証（`npm install -g` による実置換、2026-07-25）:

- 0.4.5 installで走っていた窓にbannerが出た（利用者側が確認）
- banner上の再起動で旧pidが終了し、新実体から新pidが起動する。2回とも成立
  （19:45:5x install → 19:46:03 新pid、19:53:59 新pid）
- **processは置換を越えて生き続ける**: binaryのinodeが48308211→48308499へ変わっても、
  起動中processは3秒間観測して消えなかった。macOSが署名不整合で殺すわけではなく、
  「壊れた窓が残り続ける」のが既定の結末である

## 落とし穴

- **非アクティブ窓への1回目clickは窓の前面化に消費される**（macOS標準挙動）。banner buttonが
  「効かない」ように見えて実装を疑ったが、窓をactiveにしてからの2回目で正常に動いた。GUI検証時は
  frontmost判定（`lsappinfo front` → `lsappinfo info -only pid`）を先に取る
- 失敗を1秒pollで消える汎用errorへ載せると、失敗自体が無言になる。復旧UIの失敗は復旧UIの上に残す
- **計測のための再installが、観測しようとしている状態を新しく作る。** 利用者の再起動が成功して
  新pidへ入れ替わった直後、確認のため同じ版を再installしたところ、その新pidが再び古い実体を掴む
  状態になった。その後の観測だけを見て「再起動が効いていない」と誤って結論した。原因は自分の
  再installである。**pidと起動時刻を時系列に並べてから結論する**こと。inodeの現値だけでは
  「誰がいつ壊したか」を判別できない
