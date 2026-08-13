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

契約の詳細は [../docs/architecture.md](../docs/architecture.md) §4。要点:

- 認証は `Authorization: Bearer <ベータトークン>`
- 座標はすべて**正規化float（0–1、画像左上原点）**。モデル内部の座標形式は
  サーバーが吸収し、クライアントへ漏らさない
- SSEの `delta` は表示専用。**描画は検証済みの `result` だけを信じる**

## モデル

`claude-opus-5`。選択とフォールバックは `app/api/analyze/route.ts` の1箇所だけが決める。
`fallbacks: "default"` を有効にしてあるので、安全性分類器が拒否した場合は
Anthropic推奨のフォールバックモデルが同一呼び出し内で応答する。

`effort` は `high` から始めている。**実画面で精度を測ってから下げる**こと
（roadmap M1）。速い・安いを先に選ぶと、開いたプルダウンを読めないモデルを
掴む — [../docs/lessons-from-app-mac.md](../docs/lessons-from-app-mac.md) §5。

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
