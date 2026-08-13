# セッション引き継ぎ

作成: 2026-08-14 ／ 次にやること: **M4（Macミラーリング）**

**これはある時点のスナップショットである。** 恒久的な正本は
[README.md](README.md)・[docs/architecture.md](docs/architecture.md)・
[docs/roadmap.md](docs/roadmap.md) で、内容が食い違ったらそちらが正しい。
本書は「いま何が動いていて、次に何から触るか」だけを扱う。

---

## いまどこまで出来ているか

**M1（カメラモード）の核心は通った。** iPhone 13の実機でMacのXcode画面を撮り、
「Xcodeのプロジェクト画面」であることと、表示されていた署名エラーへの正しい対処
（Signing & Capabilities で開発チームを選ぶ）を説明させることに成功している。
**画面を読んで正しい次の一手を出す、という企画の前提は実機で確認済み。**

| | 状態 |
|---|---|
| `server/` `/api/analyze`（SSE・構造化出力・パック注入） | 動作確認済み |
| iOSアプリ（カメラ→解析→写真上に枠と解説） | **実機で動作確認済み** |
| `mac/` Broadcaster | **未着手（M4でここから）** |
| 課金・アカウント | 未着手（ベータトークンのみ） |

モデルは OpenAI `gpt-5.6-luna`（Responses API）。**モデルを知っているのは
[server/lib/vision-model.ts](server/lib/vision-model.ts) 1ファイルだけ。**

## 🔴 次にやること: ハイライトのズレの調査（未解決）

**[docs/investigation-highlight-offset.md](docs/investigation-highlight-offset.md)
を読んでから着手する。** 測定手順が定義してある。

要点だけ:

- 枠が対象から200〜300pxズレる。**解説文は正しく、枠だけが違う**
- **原因は未特定。** 症状から推測して2回修正し、2回外した（EXIF焼き込みは実機に
  存在しない問題を直していた／レイアウト変更は無関係な箇所を壊した）
- **空白は「実機写真に対してモデルの座標が正しいか一度も測っていない」こと。**
  モデル側かアプリの描画側かが区別できていない
- 文書に**独立した2つの測定**（A: サーバー側で枠を描いてモデル単体を見る／
  B: アプリで決め打ち座標を描いて描画だけを見る）と判定表を定義済み。
  **確定してから直す**

**この方針は第三者のエンジニアのレビュー待ち**（文書§13に論点あり）。
レビュー結果次第で手順が変わる可能性がある。

横持ちは別問題として切り離してある（`videoOrientation` 未設定でプレビューが
回転しない）。調査中は縦持ち固定を提案しているが、これもレビュー対象。

## 動かし方

```bash
cd server && npm run dev          # 必ず dev。start はリクエストを記録しない
```

実機への流し方（Xcode不要）は [ios/README.md](ios/README.md) の
「コマンドラインだけで実機へ流す」。

- APIキーは `server/.env.local`（gitignore済み）。**`.env.example` に書かない**
  — 追跡対象なので流出する。一度やりかけた
- `ios/Local.xcconfig`（gitignore済み）に接続先とベータトークン。実機では
  `localhost` ではなく**Macのアドレス**にする（`ipconfig getifaddr en0`）
- 実機: iPhone 13 がペアリング済み。UDIDは `xcrun devicectl list devices` で取得
- **カメラはSimulatorで動かない。** M1以降の検証は実機必須

## 支払い済みの授業料（同じ穴に落ちないために）

すべてコードのコメントか関連ドキュメントに記録済み。ここは索引。

| 罠 | どこに書いてあるか |
|---|---|
| モデルに画像サイズを伝えないと**Y座標だけ**壊れる（解説文は正しいまま） | [server/lib/prompt.ts](server/lib/prompt.ts)、lessons §3-b |
| 伝えた寸法が**格納時**だと、モデルは**回転後**を見ているので同じ壊れ方をする | [server/lib/image-size.ts](server/lib/image-size.ts)、lessons §3-c |
| `URLSession.AsyncBytes.lines` は**空行を捨てる**。SSEの区切りは空行 | [ios/.../AnalyzeClient.swift](ios/UniversalIOCopilot/Services/AnalyzeClient.swift) |
| 署名Teamは証明書の**OU**。名前に出ている番号ではない | [ios/project.yml](ios/project.yml) |
| `NSLocalNetworkUsageDescription` が無いとiOSは**オフラインを装って**失敗する | [ios/project.yml](ios/project.yml) |
| xcconfig では `//` がコメント。URLのスラッシュが消える | [ios/Local.xcconfig.example](ios/Local.xcconfig.example) |
| `next start` はリクエストを記録しない。切り分けには `next dev` | [ios/README.md](ios/README.md) |

**共通する形がある。** どれも例外を投げず、**正解の顔をして間違える**か、
**無関係な場所を疑わせるエラーを出す**。iOSとAppleの権限系は特にこの傾向が強いので、
「繋がらない」系の症状では**まずサーバーログにリクエストが届いているかを見る**
（`next dev` ならログに出る）。

## M4 の進め方

**着手前に上のズレの実機確認を済ませること**（原因は特定・修正済みなので、確認だけ）。

[docs/roadmap.md](docs/roadmap.md) M4 に順序と合格ラインの枠を書いてある。要点だけ:

- **解析の背骨（サーバー・座標契約・オーバーレイ・対話）は完成済み。**
  ミラーで新しく要るのは映像の入手経路だけで、iOS側は画像の供給元を差し替える形になる
- **Macコンパニオンはサーバーと通信しない。** APIクライアントはiOSアプリだけ
  （カメラモードにMacが存在しないため。architecture.md §1）
- MPCの実測が未知数だが、**映像と解析は分離済みなので不成立でも企画は死なない**。
  最悪、映像を低fpsプレビューに退化させて解析はフル品質を保つ
- **合格ラインは測る前に roadmap へ記入する**（測った後に基準を動かさないため）
- AX候補による接地はM5。M4では踏み込まない
