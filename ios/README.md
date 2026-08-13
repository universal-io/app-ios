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
