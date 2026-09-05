# FSEvents永続checkpointの連続性

- 出典: [[raw/apple-fsevents-persistent-stream-continuity-20260721]]
- 取得日: 2026-07-21
- 確度: 高

## AIShellへの判断

AIShellの観測対象workspaceは任意のlocal volume上に置けるため、per-host streamとdevice UUIDの組合せでは永続checkpointの連続性を
証明できない。rootの`st_dev`を使うper-device streamへ統一し、そのFSEvents UUIDをcheckpointへ束縛する。次回のUUID不一致・
取得不能、又は保存event IDが現在のsystem IDより大きい場合はwarm deltaを`RESCAN_REQUIRED`で拒否する。callerが明示fullを
要求した場合だけ旧entryを捨てて新generationを構築する。

macOSのfirmlink配下（例: `/var`）ではvisible path、physical path、Data volumeのmount pointが一致しない。watch pathは
`statfs`のmount pointと`realpath`からdevice-relativeにし、callback pathはmount pointへ戻してからruntimeのcanonical path
照合へ渡す。`HistoryDone`はstream制御eventなのでfile変更としてjournalへ入れない。

FSEventsは変更候補の通知であり現在状態の正本ではない。observerをscan前に開始し、scan中のeventを同期bufferへ保持する。
drop/wrap/root-changeはpath exclusionより前に判定する。full再構築中に再度gapを検出した場合もfresh結果を返さない。

この判断によりwarm restore対象volumeを削らず、全観測対象workspaceで同じfail-closed契約を維持する。
