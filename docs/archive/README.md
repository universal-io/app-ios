# archive — 経緯の記録

**ここにあるものは現行の設計正本ではない。** 現行は [../../README.md](../../README.md) と
[../architecture.md](../architecture.md) / [../roadmap.md](../roadmap.md)。

## 旧構想（2026-08-11、app-mac資産の流用前提）

2026-08-13にオーナー判断でゼロベース設計へ切り替えた。本企画はmacOS版とはほぼ別の
プロダクトとして、専用APIサーバーを新造し、App Store課金を正とする方針になった。
以下は切り替え前の構想の記録。実測に基づく教訓は
[../lessons-from-app-mac.md](../lessons-from-app-mac.md) へ抽出済みなので、通常はそちらを読めば足りる。

| ファイル | 内容 |
|---|---|
| [handoff-from-app-mac-2026-08-11.md](handoff-from-app-mac-2026-08-11.md) | app-mac開発セッションからの引き継ぎ書。既存Gateway（`POST /api/ai/vision`）とmacOSクライアント資産の流用を前提としていた |
| [poc-spec-2026-08-11.md](poc-spec-2026-08-11.md) | オーナーによる最初のPoC仕様（原文） |

## 旧iOSアプリ（bomb-squad）の調査記録

開発終了した別プロダクト（`../../../app-ios-legacy-bomb-squad`、GitHub:
`matsumotokaya/ios-bomb-squad`）で作られた一次調査。あちらはiOSの**入力側**
（カスタムキーボード拡張＋音声入力）を狙ったもので、本企画とは別物。
調べ直すと数時間かかる内容なので保持している。

| ファイル | 内容 | 読むべき時 |
|---|---|---|
| [receiving-side-options.md](receiving-side-options.md) | iOSでサードパーティが他アプリの画面に触れる公式経路は4つしかない、という分析。呼び出しジェスチャの比較表つき | **iPhone自身の画面**を読む話が出てきた時 |
| [research-findings.md](research-findings.md) | カスタムキーボード拡張のFull Access、メモリ制約、マイク利用可否、App Review論点の一次調査（出典URL付き） | iOSから**入力欄へ注入**する話が出てきた時 |

`receiving-side-options.md` §0 の「iOS受信側は優先度低」という結論は本企画には
適用されない（あちらはiPhoneが自分の画面を読む前提。本企画は他の画面を映して読む）。
