# archive — 旧iOSアプリの調査記録

ここにあるのは、**開発終了した別プロダクト**（`../../../app-ios-legacy-bomb-squad`、
GitHub: `matsumotokaya/ios-bomb-squad`）で作られた調査ドキュメントである。
そのプロダクトはiOSの**入力側**（カスタムキーボード拡張＋音声入力）を狙ったもので、
本企画（Macの画面を映すコパイロット）とは別物。

**本企画の実装には不要。** 捨てずに置いてあるのは、調べ直すと数時間かかる内容だからで、
下の条件に当てはまる時にだけ読む。

| ファイル | 内容 | 読むべき時 |
|---|---|---|
| [receiving-side-options.md](receiving-side-options.md) | iOSでサードパーティが他アプリの画面に触れる公式経路は4つしかない、という分析。呼び出しジェスチャ（背面タップ／アクションボタン／スクショ／コントロールセンター／Siri）の比較表つき | **iPhone自身の画面**を読む話が出てきた時 |
| [research-findings.md](research-findings.md) | カスタムキーボード拡張のFull Access、メモリ制約、マイク利用可否、App Review論点の一次調査（出典URL付き） | iOSから**入力欄へ注入**する話が出てきた時 |

`receiving-side-options.md` の §0 は「iOS受信側は優先度低」と結論しているが、
**その判断は本企画には適用されない。** 理由は [../../HANDOFF.md](../../HANDOFF.md) §0 に書いてある。
前提が違う（あちらはiPhoneが自分の画面を読む話、本企画はMacの画面を映す話）。
