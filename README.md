# Universal I/O Copilot (iOS)

**手元のiPhone / iPadを「画面をわかってくれる相棒」にするアプリ。**
目の前の画面 — Macからミラーリングした画面、またはカメラで映した任意の画面 — をAIが読み、
「ここはどうすればいい？」に対して、押すべき場所に枠を打ち、次の一手を解説する。

標語は macOS版 Universal I/O と同じ「**こころに杖とメガネを**」。ただし本アプリは
**macOS版とはほぼ別のプロダクト**であり、設計はゼロベースで行う。macOS版は参考資料
（[docs/lessons-from-app-mac.md](docs/lessons-from-app-mac.md)）としてのみ扱う。

**状態: 未着手。** このリポジトリにあるのは設計ドキュメントだけで、コードはまだ無い。

---

## プロダクト定義

### コア体験（最初のバージョンで作るもの）

**ミラーリングした画面を、説明する。** それが全てである。

1. Mac の画面が iPhone / iPad にワイヤレスで映る
2. ユーザーが画面をタップ、または質問する（テキスト／音声）
3. AI が画面を解析し、対象に枠線（ハイライト）と吹き出しを重ねて描き、
   チュートリアルのように次の一手を案内する

Macの作業領域は1ピクセルも奪わない。解説とナビゲーションだけを手元の端末へ逃がす。

### 入力は2系統（同じ解析パイプラインに乗せる）

| モード | 画面の取得方法 | 対象 |
|---|---|---|
| **ミラーモード** | Mac用コンパニオンアプリがワイヤレス送信 | Macの画面 |
| **カメラモード** | iPhone/iPadのカメラで映す | あらゆる画面・機器（他のPC、プリンタ、レジ、券売機…） |

「画面を理解して案内する」という中核はどちらも同じ。ミラーモードが本命だが、
カメラモードはMacを持たない相手の機器にも届く自然な延長である。

### 最大の差別化: 独自コンテキスト

汎用チャットAIにスクショを貼れば一般論は返ってくる。本アプリの価値は
**組織・個人ごとの独自コンテキスト（コンテキストパック）を注入できる**ことにある。

- 社内システムの操作手順、社内プロトコル、独自ルール
- 「この画面のこのボタンは、うちの会社では押してはいけない」レベルの固有知識
- これにより案内が一般論ではなく **その組織の正解** になる

Go-to-Market はここに置く。個人向け（アクセシビリティ・学習支援）で体験を磨き、
ビジネス（社内システムのオンボーディング・ヘルプデスク削減）で収益化する。
セキュリティ要件など導入ハードルは高いが、同種のプロダクトは存在しない。

### 将来の延長線（最初のバージョンでは作らない）

- **リモート操作**: iOS側から「このボタンを押して」→ Macホストが実際にクリックする。
  ミラー（見る）→ ナビゲーション（教える）→ リモコン（代わりに操作する）の最終形
- 音声での連続対話、操作の自動追従（Copilotループ）

---

## アーキテクチャ（要約）

```
[ Mac コンパニオン（Broadcaster）]        ← 薄い送信専用アプリ（新規）
  ├ ScreenCaptureKit で画面取得
  ├ （可能なら）Accessibility で操作候補を添付
  └ MultipeerConnectivity で iOS へ送信
        │
        ▼
[ iOS / iPadOS アプリ ]                   ← プロダクト本体
  ├ ミラーモード: 映像ストリーム再生（AVSampleBufferDisplayLayer）
  ├ カメラモード: AVFoundation カメラ
  ├ Overlay Layer: 透明な SwiftUI Canvas（枠線・吹き出し）
  └ タップ / 質問 → 解析要求
        │
        ▼
[ API サーバー（新規・本プロダクト専用）]
  └ POST /api/analyze
     モデル選択・APIキー保持・コンテキストパック注入・利用制御
```

**API クライアントは iOS アプリだけ**である（カメラモードにはMacが存在しないため、
解析の主体はiOS側に置くのが自然）。Macコンパニオンはフレームと補助情報を送るだけの
薄い存在に保つ。

**譲れない規則が1つだけある: AIプロバイダのAPIキーを端末に置かない。**
モデルの呼び出しは必ず自前のAPIサーバー経由で行う。これはmacOS版から引き継ぐ
唯一のアーキテクチャ規則である（理由は [docs/lessons-from-app-mac.md](docs/lessons-from-app-mac.md) §1）。
サーバーは既存Gatewayの流用ではなく、このプロダクトのために最小構成で新造する。

詳細は [docs/architecture.md](docs/architecture.md)。

---

## 課金の方針

- **正規のApp Store課金（IAP / StoreKit 2 のサブスクリプション）を正とする。**
  Webでの外部購入導線は作らない（審査ガイドライン3.1.1と正面衝突しないため）
- ただし**開発が進むまでは課金を実装しない**。ベータ期間はTestFlightで無料配布し、
  サーバー側の利用制御（ベータトークン＋レート制限）だけで運用する
- B2B（コンテキストパックの組織導入）は将来的に別契約（Volume Purchase /
  カスタムApp / 直接契約）を検討するが、今は方向性の記録のみ

---

## リポジトリ構成

```
app-ios/
├── ios/        ← iOSアプリ本体（XcodeGen。カメラモード実装済み）
├── server/     ← APIサーバー（Next.js。/api/analyze 実装済み）
├── mac/        ← Macコンパニオン（Broadcaster）※ロードマップM4で追加
└── docs/       ← 設計ドキュメント
```

macOS版（`../app-mac`）とは独立して開発・デプロイする。コードの共有はしない。
参考にしたい実装があれば読みに行くのは自由だが、依存は作らない。

## 動かす

```bash
cd server && npm install && cp .env.example .env.local   # APIキーとベータトークンを設定
npm run dev

cd ../ios && cp Local.xcconfig.example Local.xcconfig && xcodegen generate
open UniversalIOCopilot.xcodeproj
```

詳細は [ios/README.md](ios/README.md) と [server/README.md](server/README.md)。

---

## 読む順序

| # | 読むもの | 何が分かるか |
|---|---|---|
| 0 | [**HANDOFF.md**](HANDOFF.md) | **いま何が動いていて次に何から触るか。セッションを引き継ぐならここから** |
| 1 | **このREADME** | プロダクト定義と方針 |
| 2 | [docs/architecture.md](docs/architecture.md) | システム設計・API契約・セキュリティ |
| 3 | [docs/roadmap.md](docs/roadmap.md) | 実装順序とマイルストーン |
| 4 | [docs/lessons-from-app-mac.md](docs/lessons-from-app-mac.md) | macOS版が実測で得た教訓のうち、本企画でも通用するもの |
| 5 | [docs/investigation-highlight-offset.md](docs/investigation-highlight-offset.md) | **未解決の調査。ハイライトの位置がズレる原因の切り分け手順** |

[docs/archive/](docs/archive/) には旧構想（app-mac資産の流用前提だった引き継ぎ書・PoC仕様）と、
さらに前の旧iOSアプリの調査記録がある。**現行の設計はこのREADMEと上記docsが正**であり、
archiveは経緯の記録である。

---

## 進め方の原則

- **測ってから決める。** 「速そう」「読めそう」で判断せず、実機で数値を取ってから設計を確定する
- **最大の未知数から潰す。** 最初のマイルストーンはMultipeerConnectivityの映像伝送実測
  （[docs/roadmap.md](docs/roadmap.md) M1）。ここが崩れると企画の形が変わる
- **分からないことは推測で進めず、確認する**

## 開発環境

- 連携先Mac（実測・開発機）: MacBook Pro 16インチ 2021（Apple M1 Pro / 16GB）
  macOS 26.5.2 (25F84)
- iOS側ターゲット: iOS 17+（SwiftUI）
