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

## ハイライトのズレ: 解決済み（2026-08-14、実機確認済み）

**原因は2つあり、どちらもアプリの座標変換ではなかった。** 経緯と外し方の記録は
[docs/investigation-highlight-offset.md](docs/investigation-highlight-offset.md)。

1. **送る画像が大きすぎた** — 実寸3024×4032で命中3/11。長辺1536に制限して18/18
2. **座標をモデルに目測させていた** — OCRの実測矩形を `candidates` で渡すようにした

決め手は**サーバーが受け取ったバイトに、返した座標で枠を描いて人間が見る**測定
（`UIO_DEBUG_CAPTURE_DIR` + `server/scripts/draw-boxes.py`）。1枚で決着した。

**同時に、Apple標準の回転実装（`AVCaptureDevice.RotationCoordinator`）が
丸ごと欠けていたのを入れた。** 縦・横・逆さで正立する。横持ちは「難しいから後回し」
ではなく、公式手順が未実装だっただけだった。

### M1で残したもの（M4より優先ではない）

- 文字のないアイコンボタンは接地できない（測る対象が無い）。モデルの目測に戻る
- **枠が文字に吸い付き、文字が読みにくい。** 描画の調整で直る。座標の問題ではない
- **横持ちは座標は合うがレイアウトが実用に耐えない。** 映像が上半分に潰れて
  文字が読めない。**映像を全画面に敷きUIをオーバーレイする方針**へ寄せる
  （roadmap M1「レイアウトの方針」）。ミラーモードも同じ問題に当たる
- **タップで対象を指定する経路が未接続。** `ContentView` の `pendingTap` は
  宣言されているが値が設定されず、常に nil のまま送られている。測定では
  タップ座標があると精度が上がるので、入れる価値がある

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
| **写真は実寸で送ると座標が壊れる。**「縮小すると読み違える」は逆だった | [ios/.../AnalysisSession.swift](ios/UniversalIOCopilot/ViewModels/AnalysisSession.swift)、lessons §3-d |
| 誤差は**バイモーダル**。平均で見て定数補正すると当たっている回を壊す | investigation §4 |
| ポート3000を**別プロジェクトのサーバー**が握っていると、HTMLが返って解析だけ失敗する | 下記 |
| `URLSession.AsyncBytes.lines` は**空行を捨てる**。SSEの区切りは空行 | [ios/.../AnalyzeClient.swift](ios/UniversalIOCopilot/Services/AnalyzeClient.swift) |
| 署名Teamは証明書の**OU**。名前に出ている番号ではない | [ios/project.yml](ios/project.yml) |
| `NSLocalNetworkUsageDescription` が無いとiOSは**オフラインを装って**失敗する | [ios/project.yml](ios/project.yml) |
| xcconfig では `//` がコメント。URLのスラッシュが消える | [ios/Local.xcconfig.example](ios/Local.xcconfig.example) |
| `next start` はリクエストを記録しない。切り分けには `next dev` | [ios/README.md](ios/README.md) |

**共通する形がある。** どれも例外を投げず、**正解の顔をして間違える**か、
**無関係な場所を疑わせるエラーを出す**。iOSとAppleの権限系は特にこの傾向が強いので、
「繋がらない」系の症状では**まずサーバーログにリクエストが届いているかを見る**
（`next dev` ならログに出る）。

ポートの件も同じ形だった。別プロジェクトのNext.jsが3000を握っていて、
`/api/analyze` にHTMLを返すため、アプリ側は解析だけが失敗する。回転の実装を
疑わせる出方をした。**自分のサーバーかどうかは応答で判定できる**:

```bash
curl -s -m 5 http://localhost:3000/api/analyze -X POST \
  -H "content-type: application/json" -d '{}'
# 期待: {"error":{"code":"UNAUTHENTICATED", ...}}   HTMLが返ったら別人のサーバー
lsof -nP -iTCP:3000 -sTCP:LISTEN -t | xargs -I{} lsof -a -p {} -d cwd -Fn | grep ^n
```

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
