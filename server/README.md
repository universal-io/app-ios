# 解析サーバー

iOSアプリ専用のAPI。**AIプロバイダのAPIキーを持つのはここだけ**で、
クライアントはモデル名を知らない（[../docs/architecture.md](../docs/architecture.md) §1）。

## セットアップ

```bash
npm install
cp .env.example .env.local   # ANTHROPIC_API_KEY と BETA_TOKENS を設定
npm run dev
```

## エンドポイント

| メソッド | パス | 用途 |
|---|---|---|
| `POST` | `/api/analyze` | 画像1枚を解析し、解説とアノテーションをSSEで返す |
| `GET` | `/api/packs` | 利用可能なコンテキストパックのID一覧 |
| `POST` `GET` | `/api/mirror/frame` | **実験用**。ブラウザ送信の中継（下記） |
| `GET` | `/api/mirror/time` | **実験用**。2台の時計を突き合わせるためのサーバー時刻 |

## 実験: Macに何もインストールせずに画面を送る

**問い**: ブラウザの画面共有（`getDisplayMedia`）だけで、M4が native 経路に課したのと
同じ基準（**片道300ms以内・文字が読める**）を満たせるか。

```bash
npm run dev
```

| 開く場所 | URL |
|---|---|
| Mac（送信） | `http://localhost:3000/mirror-send.html` |
| iPhone（受信） | `http://<Macのアドレス>:3000/mirror-view.html` |

**送信側は必ず `localhost` で開く。** 画面共有はsecure contextにしか提供されず、
LANのIPアドレスはそれに該当しない（`localhost` は該当する）。受信側は特権を必要と
しないので、素のhttpで問題ない。

受信ページの左端に**片道遅延**が出る（300ms以内なら緑）。送信ページには
エンコード時間・帯域・実fpsが出るので、**遅いときにどこが遅いのかが分かる**。

**これは計測用の足場であって、製品の伝送路ではない。** JPEGをHTTPで1枚ずつ運んで
いるだけで、本番なら WebRTC で H.264 を直接送る。したがってここで出る数字は
**ブラウザ経路のコストの上限**である。通れば問いは片付く。通らなければ否定されたのは
この足場であって、ブラウザ送信そのものではない。

契約の詳細は [../docs/architecture.md](../docs/architecture.md) §4。要点:

- 認証は `Authorization: Bearer <ベータトークン>`
- 座標はすべて**正規化float（0–1、画像左上原点）**。モデル内部の座標形式は
  サーバーが吸収し、クライアントへ漏らさない
- SSEの `delta` は表示専用。**描画は検証済みの `result` だけを信じる**

## モデル

**OpenAI `gpt-5.6-luna`（Responses API）**。Vision対応で、速度と単価が現時点で最良。
`../app-mac` のGatewayが本番で使っている一次モデルと同じで、呼び出しの形も
そこで実証済みのものに合わせてある（`store: false`、`reasoning.effort: "none"`、
`detail: "original"`、SSEの `response.output_text.delta`）。

**モデルを知っているのは [lib/vision-model.ts](lib/vision-model.ts) だけ。**
差し替えはこのファイル1つで完結し、`/api/analyze` の契約は動かない。

- `store: false` は**チューニング対象ではない**。画面には第三者の情報が映り得るので、
  保持しない約束は製品の一部
- `reasoning.effort` は `"none"`。速度優先で選んだモデルなので既定はこれ。
  **実画面で精度を測ってから**上げ下げすること（roadmap M1）。
  速い・安いを先に選ぶと、開いたプルダウンを読めないモデルを掴む —
  [../docs/lessons-from-app-mac.md](../docs/lessons-from-app-mac.md) §5
- 画像は `detail: "original"`。縮小は数字の誤読を招く（同 §3）

SDKではなく `fetch` を直接使っている。このモデルの機能（`detail: "original"` 等）を
公開SDKの型が網羅している保証がなく、app-mac が同じ理由で同じ選択をしているため。

## コンテキストパック

`context-packs/*.md` がそのままパック。ファイル名（拡張子なし）がIDになる。

パックは**プロンプトへ注入されるデータであり、制御フローに触れない**。
該当しないパックを指定しても、存在しないIDを指定しても、汎用経路がそのまま動く。
適用中のパックは `result.applied_context_pack` で返り、**アプリは必ず表示する**
（見えない知識は疑うことも直すこともできない）。

## ベータ期の制限

- 認証はビルド埋め込みトークン。アカウントとStoreKitのエンタイトルメントは製品期に入れる
- レート制限はプロセスローカル。インスタンスをまたがないので、暴走クライアントを
  止める用途にとどまる。広く配る前に共有ストアへ移す
