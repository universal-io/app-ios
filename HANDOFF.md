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

## ハイライトのズレ: 原因はバグで、修正済み（実機での確認だけ残っている）

**チューニングではなく EXIF orientation のバグだった。** カメラJPEGは画素を撮像時の
向きで格納し回転はEXIFで指示するため、**モデルは回転後を見るのにサーバーは格納時の
寸法を伝えていた**。縦軸だけ誤った分母で割られ、写真も解説文も正しいまま枠だけが上へ
ズレる。数値の一致まで確認した（[docs/roadmap.md](docs/roadmap.md) 実測2）。

修正は2箇所。**iOSで向きを画素に焼き込む**（送るバイトと描画対象を同一画像にする）と、
**サーバーでEXIFを読んで寸法を入れ替える**（他クライアント向けの防御）。
合成画像では修正後 `x=0.828 / y=0.825` と正解に完全一致。

**残っているのは実機での確認だけ。** 修正版はビルド済みだがインストールが実機の
スリープ待ちで未実施。次のセッションの最初にこれを済ませる:

```bash
cd server && npm run dev     # 別ターミナルで起動したまま
# iPhoneのロックを解除してから ios/README.md の「コマンドラインだけで実機へ流す」
```

撮り直して**枠の中心が対象内に入る率 9/10 以上**を確認できたらM1完了。
そのあと画像の縮小（コストと帯域のため。速度は問題になっていない）。

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
