# Universal I/O for iOS — Copilot Screen

**手元のiPhone / iPadを、Macの作業画面を映す卓上コパイロットモニターにするアプリ。**
Macの画面をワイヤレスでミラーリングし、iOS側で「ここはどうすればいい？」と画面をタップまたは
質問すると、画面を理解したAIが押すべき場所に枠を打ち、解説を出す。

**状態: 未着手。** このリポジトリにあるのは設計ドキュメントだけで、コードは1行も無い。
ゼロベースで設計・実装を始める段階である。

---

## まず知っておくこと

### これは新規プロダクトではなく、既存プロダクトの拡張である

Universal I/O は**認知拡張プラットフォーム**である。認知特性・言語・スキル・知識の違いから
生まれるデジタル機器操作の困りごとを解消する。標語は「**こころに杖とメガネを**」。

macOS版は**すでに公開・稼働している**（`v0.2.2`、2026-08-11公開）。画面を読んで案内する
機能（Vision / Copilot）、文章作成の支援、音声入力、課金、アカウント管理まで動いている。

**本アプリは、そのmacOS版の「見る→わかる→案内する」体験を、iPhone/iPadという第二の画面へ
持ち出すものである。** 作業はMac上に残したまま、解説とナビゲーションだけを手元の端末へ逃がす。
Macの作業領域を1ピクセルも占有しないのが要点。

### 必読・必須チェックアウト: macOS版リポジトリ

```
git@github.com:universal-io/app-mac.git
```

**このリポジトリの兄弟ディレクトリとしてcloneすること。** 本リポジトリのドキュメントは
`../app-mac/...` という相対パスで参照する。

```
projects/universal-io/
├── app-mac/                     ← 必須。macOSクライアント + Gateway（サーバー）
├── app-ios/                     ← このリポジトリ
└── app-ios-legacy-bomb-squad/   ← 旧iOSアプリ（開発終了・参照不要）
```

`app-mac` には2つのものが入っている。両方とも本アプリに直接関係する。

1. **macOSクライアント**（`BombSquad/`）— 画面キャプチャ、Accessibility走査、
   ハイライト描画。本アプリのMacホスト側は、ここのコードを流用して作る
2. **Gateway**（`web/`）— **全クライアント共通のサーバー**。AIモデルの選択、認証、
   利用計上、プロンプト、精度レイヤー（Skills）がすべてここにある

### 絶対規則: AIプロバイダを直接呼ばない

**クライアントは OpenAI / Google / Groq を直接呼ばない。** 認証済みの全AIリクエストは
`https://api.universal-io.com` の本番Gatewayへ送る。

これは設計の好みではない。直接呼ぶと、モデルのfallback、課金と利用制限、データ保持の約束
（ZDR）、精度レイヤー、プロンプト本体がすべて機能しなくなり、APIキーを端末に置くことになる。

**本アプリは既存の `POST /api/ai/vision` をそのまま使う。** 新しいendpointもmodel routeも
作らない。詳細は [HANDOFF.md](HANDOFF.md) §1。

---

## 読む順序

| # | 読むもの | 何が分かるか |
|---|---|---|
| 1 | **このREADME** | 全体像と、参照すべき場所 |
| 2 | [**HANDOFF.md**](HANDOFF.md) | **既存資産の何を流用し、仕様のどこを修正するか。着手前に必読** |
| 3 | [docs/poc-spec.md](docs/poc-spec.md) | オーナーが定義したPoC仕様（原文）。HANDOFF.mdに上書きされた箇所あり |
| 4 | `../app-mac/README.md` | 現行プロダクトが何をどう実現しているか |
| 5 | `../app-mac/docs/design-philosophy.md` | 北極星（ユーザー起点の世界モデル）と、作る順序の思想 |
| 6 | `../app-mac/docs/api-contract.md` | Gatewayの契約 |

急ぐ場合でも **2 は飛ばさないこと。** 数か月かけて到達した結論と、その理由が書いてある。
知らずに作ると、すでに一度捨てられた設計を作り直すことになる。

---

## アーキテクチャ（要約）

```
[ macOS ホスト ]
  ├ ScreenCaptureKit で画面取得        ← ../app-mac に実装あり
  ├ Accessibility で操作候補を走査      ← ../app-mac に実装あり
  └ MultipeerConnectivity で iOS へ送信 ← 新規開発（唯一の未知数）
        │
        ▼
[ iOS / iPadOS クライアント ]
  ├ Base Layer    : 映像ストリーム再生（AVSampleBufferDisplayLayer）
  ├ Overlay Layer : 透明な SwiftUI Canvas（枠線・吹き出し）
  └ タップ → 解析要求
        │
        ▼
[ Gateway  api.universal-io.com ]  ← ../app-mac/web。変更しない
  └ POST /api/ai/vision
     モデル選択・fallback・認証・利用計上・Skills・プロンプト
```

**新規開発は実質2つしかない** — MultipeerConnectivityによる映像伝送と、iOS側のオーバーレイ描画。
残りは既存資産の流用である。詳細と根拠は [HANDOFF.md](HANDOFF.md) §3・§4。

---

## 開発を始める前のチェック

- [ ] `../app-mac` をcloneしたか
- [ ] [HANDOFF.md](HANDOFF.md) を最後まで読んだか
- [ ] Gatewayを直接呼ぶのではなく、AIプロバイダを直接呼ばない理由を理解したか
- [ ] 最初のマイルストーンが「MultipeerConnectivityの実測」である理由を理解したか
      （ここが成立しなければ企画の形が変わるため。HANDOFF.md §4-1）

---

## このプロジェクトの進め方

**測ってから決める。** macOS版はこの原則で動いている。「速そう」「読めそう」で判断せず、
実機で数値を取ってから設計を確定する。過去に、遅くて安いモデルへ切り替える判断を実測で
撤回した例、画像解像度を実測で1/3.7に削った例、AX走査を実測で2.3〜8倍にした例がある。
いずれも推測では逆の結論になっていた。

**分からないことは推測で進めず、確認する。** 環境変数、エンドポイント、仕様が不明なときは
止めて聞く。

---

## 旧iOSアプリについて

`../app-ios-legacy-bomb-squad`（GitHub: `matsumotokaya/ios-bomb-squad`）は、iOSの
**入力側**（キーボード拡張＋音声入力）を狙った別プロダクトで、**開発終了。参照不要。**

ただし調査ドキュメント2件だけは価値があるため、[docs/archive/](docs/archive/) に取り込んである。
将来「iPhone自身の画面を扱う」「iOSで入力欄へ注入する」という話が戻ってきた時にだけ読む。
本企画には不要。
