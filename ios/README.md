# iOSアプリ

現行はカメラモードのみ（[../docs/roadmap.md](../docs/roadmap.md) M1）。
ミラーモードはM4で追加する。

## セットアップ

```bash
cp Local.xcconfig.example Local.xcconfig   # 初回のみ
xcodegen generate
open UniversalIOCopilot.xcodeproj
```

**`.xcodeproj` は生成物であり、gitに入れない。** 正本は `project.yml` で、
ファイルを追加したら `xcodegen generate` を再実行する。

サーバーは別途起動しておく:

```bash
cd ../server && npm run dev
```

## 実機で動かす（カメラモードはSimulator不可）

**Simulatorにはカメラが無いので、M1の検証は実機でしか行えない。** 実機で動かすときは
2点変える。

1. `Local.xcconfig` の `UIO_API_BASE_URL` を **Macのアドレス**にする。実機から見た
   `localhost` は実機自身であって、Macではない。`ipconfig getifaddr en0` で取得し、
   MacとiPhone/iPadを同じWi-Fiに置く
2. 署名Teamは `project.yml` に設定済み（`DEVELOPMENT_TEAM`）。Xcodeの画面で触る必要はない

平文HTTPでMacに繋ぐのは `NSAllowsLocalNetworking`、LAN内への接続は
`NSLocalNetworkUsageDescription` で許可済み。**後者が無いとiOSは許可を求めず、
オフラインを装って失敗する**（一度これで詰まった）。

### コマンドラインだけで実機へ流す

Xcodeを開かずに、ビルド・インストール・起動まで通る。`-allowProvisioningUpdates`
が無いとプロファイルの更新ができずに落ちる。

```bash
DEV=$(xcrun devicectl list devices | awk '/available/ {print $3; exit}')

xcodebuild -project UniversalIOCopilot.xcodeproj -scheme UniversalIOCopilot \
  -destination "id=$DEV" -derivedDataPath /tmp/uio-dd \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device $DEV \
  "/tmp/uio-dd/Build/Products/Debug-iphoneos/Copilot Dev.app"

xcrun devicectl device process launch --device $DEV \
  --terminate-existing com.universalio.copilot.dev
```

- 起動が `device was not, or could not be, unlocked` で失敗したら、iPhoneのロックを
  解除する（インストールはロック中でも通る）
- iOSの権限判断をリセットしたいときは
  `xcrun devicectl device uninstall app --device $DEV com.universalio.copilot.dev`
  してから入れ直す
- サーバーは **`npm run dev` で起動する。`next start` はリクエストを記録しないので、
  実機からの通信が届いているかを判定できない**（これで切り分けに失敗した）

## 設定値

`Local.xcconfig`（gitignore済み）の2つだけ。ビルド時にInfo.plistへ入り、
実行時に `AppConfig` が読む。

| キー | 意味 |
|---|---|
| `UIO_API_BASE_URL` | 解析サーバーのURL。既定はローカル |
| `UIO_BETA_TOKEN` | サーバーの `BETA_TOKENS` のいずれかと一致させる |

## Debug と Release で正体が違う

| 構成 | bundle ID | アプリ名 |
|---|---|---|
| Debug | `com.universalio.copilot.dev` | Copilot Dev |
| Release | `com.universalio.copilot` | Copilot |

分けている理由は [../docs/lessons-from-app-mac.md](../docs/lessons-from-app-mac.md) §7。
開発ビルドが本番アプリの登録とTCC許可を奪わないようにするため。

## 構成

| パス | 役割 |
|---|---|
| `Models/Analysis.swift` | サーバー契約に対応する型。座標は正規化のまま保持する |
| `Support/OverlayGeometry.swift` | **正規化座標 ⇄ 表示ポイント変換。レターボックス補正はここ1箇所だけ** |
| `Services/AnalyzeClient.swift` | `/api/analyze` のSSEクライアント。AIプロバイダは直接呼ばない |
| `Services/CameraService.swift` | AVFoundationの静止画キャプチャ |
| `ViewModels/AnalysisSession.swift` | 1回の解析ラウンドの状態 |
| `Views/` | カメラプレビュー、オーバーレイ描画、画面本体 |
