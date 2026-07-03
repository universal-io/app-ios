# BOMB SQUAD (iOS)

コミュニケーションの中に含まれる「爆弾（攻撃性・トゲ）」を、送る前／受け取る前に取り除く中間レイヤー。
Slack・Gmail・チャット等の**入力の手前にステージング層を物理的に挟み**、AI でレビュー（トゲ取り・構造化）してから本番（入力欄）へ「デプロイ」する。発想は macOS ネイティブ版 **「just a moment」** と同じで、本リポジトリはその **iOS 版**。

> このファイルが入口（ハブ）です。まずここを最後まで読めば全体像と現状が分かります。
> 設計の背景となった技術調査は [docs/research-findings.md](docs/research-findings.md) に要点をまとめています。

- **元 macOS 版（コンセプトとプロンプトの正本）**: `/Users/kaya.matsumoto/projects/just-a-moment`
  - 特に `JustAMoment/Resources/ReviewPrompt.swift`（トゲ取り/受信変換のシステムプロンプト）、
    `Models/ReviewResult.swift`（構造化スキーマ `issues / revised_text / summary`）、
    `Services/ReviewProvider.swift`（LLM 抽象）は iOS 版でもそのまま流用する。

---

## 1. プロダクトの核（何を作っているか）

- **送信側（compose）**: 自分の下書きから攻撃性・圧・皮肉・詰問を取り除き、要件だけ穏やかに伝わる文に変換。
- **受信側（transform）**: 相手の攻撃的・難解なメッセージを「結局何を求めているか」に構造化（読解支援）。iOS では未着手（将来）。
- **GTM の核**: 「音声入力 → テキスト化 → トゲ取り」を 1 フローに統合すること。WhisperFlow（Wispr Flow）等の音声キーボードが立ち上げた市場に、**コミュニケーションの安全レイヤー**という差別化を乗せる。差別化は ASR 精度ではなく「人間関係コストを下げる」点。

---

## 2. 現状サマリ（どこまで動くか）

実機（iPhone 13 / iOS 26.5）で確認済み。

| マイルストーン | 内容 | 状態 |
|---|---|---|
| M1 | キーボード拡張のインストール・切替・テキスト注入 | ✅ 動作 |
| M2a | 主アプリでオンデバイス音声認識（iOS 26 SpeechAnalyzer）、喋る→逐次テキスト | ✅ 動作 |
| M2b | ハンドオフ：キーボード→主アプリ起動→録音→結果を入力欄へ注入 | ✅ 動作 |
| M3 | バックグラウンド録音＋プロセス間ライブ共有＋その場注入 | ✅ 動作 |
| M3.5 | セッション維持（Start/Stop をキーボード内で再開、一時停止） | ✅ 実装済み |
| — | **LLM トゲ取り（本丸の差別化）** | ❌ 未実装 |
| — | 完全自動復帰（元アプリへ無操作で戻す） | ⚠️ 継続調査だが現状困難 |

**今のアプリは「どのアプリの入力欄にも声で入力できる音声キーボード」までは到達。だが BOMB SQUAD の本体であるトゲ取りはまだ入っていない。**

### 2026-06-28 時点の判断メモ

- **やったこと**：キーボード起動時の戻り案内を「戻るためだけの画面」に整理し、初回アンロック後はキーボード側の `Start / Stop` だけで録音の再開・一時停止ができる keep-alive を入れた。
- **方向転換したこと**：`suspend` や host app 自動復帰系の挙動を追うのはやめ、**iOS 標準の戻る導線（左上の戻りチップ / ホームバー右スワイプ）を前提**に UX を組み立てる方針に切り替えた。
- **残タスクとして残すこと**：元アプリへの完全自動復帰は公開 API では詰まっており、今後も調査は続けるが、短期的な勝ち筋は keep-alive と LLM 部分の完成。

---

## 3. アーキテクチャ決定（なぜそうしたか）

- **ターゲット iOS 26+**：純正 `SpeechAnalyzer/SpeechTranscriber` が使える。モデルがシステム側メモリで動きアプリ実行メモリを増やさないため、キーボード拡張の厳しいメモリ制約と相性が良い。
- **app-assisted keyboard（キーボード単体で完結しない）**：iOS はキーボード拡張からのマイク録音を許さない（§4）。よって**録音・認識は主アプリ**が担い、キーボードは入力 UI と注入に徹する。
- **バックエンドは段階移行**：クライアントは自前契約だけを見る設計にし、v1 は BYOK（各自の API キー直叩き、サーバー不要）、将来 Proxy + サブスクに差し替える。ASR はオンデバイスで通信・課金ゼロなので、当面 LLM（トゲ取り）だけがバックエンド論点。
- **IPC は App Group の共有ファイル**：`UserDefaults(suiteName:)` はプロセス間でキャッシュされ伝播が遅い（実測で十数秒の遅延）。共有コンテナ内のファイルを atomic 書き込み＋毎ポーリング読みにして低遅延化。

---

## 4. iOS の硬い制約（重要・実機で確認済みの既知事実）

ここを知らないと同じ壁に何度もぶつかる。

1. **キーボード拡張のプロセスではマイク録音できない**。`AVAudioEngine.start()` が CoreAudio エラー `'what'`(=2003329396) で失敗。→ 録音は主アプリに寄せる（ハンドオフ）。Wispr もこれが理由でアプリ往復している。
2. **「自分を起動した元アプリ」へ自動復帰する公開 API は存在しない**。非公開 `suspend` セレクタは**元アプリではなくホーム画面に落ちる**ので役に立たない（既定で無効化）。現実解は iOS が出す「‹ AppName」チップを**手動 1 タップ**、または**セッションを生かして往復自体を減らす**こと。
3. **`UITextDocumentProxy` はカーソル近傍の読み書き・挿入・削除のみ**。フィールド全文取得やテキスト選択は不可。→ 自前バッファで管理し注入する。
4. **キーボード拡張のメモリは ~30–48MB（超過で kill）**。重いモデル・WebView を載せない。
5. **マイク権限のダイアログはキーボード拡張から出せない**。権限取得は主アプリで行い、拡張は許可済み前提で動く。
6. **Full Access（`RequestsOpenAccess`）必須**：ネットワーク・App Group・主アプリ起動に必要。ユーザーが設定で手動オン。審査では用途説明が要る。

---

## 5. コード構成

XcodeGen で生成（`project.yml` が正本）。ターゲットは 2 つ。

```
app-ios/
  project.yml                       # XcodeGen 定義（正本）。Team/署名/URLスキーム/背景音声もここ
  BombSquad/                        # 主アプリ（ホスト）
    BombSquadApp.swift              #  @main。bombsquad://record を受けて録音起動
    ContentView.swift              #  ホスト画面（有効化案内・音声テスト・ここで試す欄）
    BombSquad.entitlements         #  App Group
  Shared/                           # 主アプリのみが使う共有コード
    SpeechService.swift            #  iOS26 SpeechAnalyzer によるオンデバイス逐次音声認識
    DictationCoordinator.swift     #  起動→録音→ライブ共有→停止監視→（戻り方式 A/B フラグ）
  Common/                           # 主アプリ・キーボード両方が使う
    SharedStore.swift              #  App Group 共有ファイルによる IPC（ライブ転写/停止シグナル）
  BombSquadKeyboard/                # キーボード拡張
    KeyboardViewController.swift   #  UI、Start（ハンドオフ）、表示中ポーリング注入
    Info.plist                     #  NSExtension / RequestsOpenAccess=true / マイク用途
    BombSquadKeyboard.entitlements #  App Group
```

App Group ID: `group.com.matsumotokaya.bombsquad`。
Bundle ID: アプリ `com.matsumotokaya.bombsquad` / キーボード `com.matsumotokaya.bombsquad.keyboard`。
URL スキーム: `bombsquad://record`（キーボード→主アプリのハンドオフ用）。

### 現状の動作フロー（M3 POC）
```
キーボードで Start
  → bombsquad://record で主アプリを開く（初回アンロック。RequestsOpenAccess 必須）
  → DictationCoordinator が録音開始（SpeechService、背景音声で継続）
  → 主アプリは「元のアプリに戻って話す」だけのシンプル画面を表示
  → 認識結果（finalized/volatile）を SharedStore.publishLive で live.json に逐次書込
  → ユーザーが元アプリへ戻る（「‹ AppName」チップ等。自動復帰は不可）
  → キーボードが表示中ポーリングで live.json を読み、finalized 差分＋volatile を入力欄へ注入
  → キーボードの Stop は「完全停止」ではなく一時停止。一定時間内の Start で主アプリへ戻らず再開
  → タイムアウト経過後または明示終了時のみセッションを完全停止
```

---

## 6. ビルド & 実機デプロイ

### 前提（初回のみ・人手）
- Xcode 26.x / iOS 26.x SDK / `xcodegen`（Homebrew）
- 署名: 自動署名・Team `TG68TFXG88`・キーチェーンの「Apple Development」証明書
- **Xcode > Settings > Accounts に Apple ID をログイン済み**であること（無いと `No Accounts` で署名失敗）
- **developer.apple.com で最新の Program License Agreement に同意済み**であること（未同意だと `PLA Update available` で失敗）

### コマンド
```bash
cd app-ios
xcodegen generate            # project.yml から .xcodeproj を生成

# シミュレータ（コンパイル確認向け。マイクは不安定）
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad \
  -sdk iphonesimulator26.5 -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# 実機（音声テストは必ず実機。要 USB ケーブル接続）
xcodebuild -project BombSquad.xcodeproj -scheme BombSquad \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates build
APP="$(echo ~/Library/Developer/Xcode/DerivedData/BombSquad-*/Build/Products/Debug-iphoneos/BombSquad.app)"
xcrun devicectl list devices                                   # 端末の UDID を確認
xcrun devicectl device install app --device <UDID> "$APP"
xcrun devicectl device process launch --device <UDID> com.matsumotokaya.bombsquad
```

### 実機での手動操作（自動化不可）
- キーボード追加: 設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → BOMB SQUAD
- フルアクセス: 同 → BOMB SQUAD → 「フルアクセスを許可」をオン
- 端末は **Developer Mode 有効** + **USB ケーブル接続**（Wi-Fi 接続だと developer disk image マウント不可でデプロイ失敗）

---

## 7. 既知の課題 / 未解決

- **1 回目の注入が入らないことがある**（再現条件: 入力欄に既存テキストがある状態での初回）。原因未特定。デバッグ時は `pollLiveTranscript` にポーリング回数・session 有無・finalized/consumed・`textDocumentProxy.hasText` をプレビュー表示する診断を仕込むと切り分けられる。
- **遅延**：入力欄が遅い主因は「確定（finalized）待ち」だった。volatile も即時注入する方式で緩和済み（プレビュー欄は元から即時）。IPC/タイマーは遅延要因ではない（プレビューが即時だったのが証拠）。タイマーは `.common` モードで常時発火させている。
- **戻り（return）UX**：自動復帰は不可（§4-2）。現状は手動。根本対策はセッション維持で往復を減らすこと。
- **セッション維持は入ったが暫定**：現在は「一時停止後 5 分で自動終了」の暫定値。バックグラウンド維持時間、無音時の扱い、ユーザーへの明示方法は再設計余地が大きい。
- **完全自動復帰は未解決**：現状の iOS 26.5 では公開 API での実現手段を確認できていない。継続調査項目として残すが、当面は keep-alive 前提で進める。
- **背景録音中はマイク使用インジケータ（オレンジ点）が出続ける**：プライバシー表示として正しい挙動。Live Activity 等での明示が将来必要。

---

## 8. ロードマップ（次にやること）

1. **セッション維持の磨き**：keep-alive 自体は入った。次はタイムアウト長、無音時の自動停止、再開時の文脈リセット、UI 上の状態表示を詰める。
2. **LLM トゲ取り（本丸）**：プレビュー欄を**ステージング作業場**に。`喋る→原文がステージングに溜まる→（必要なら）レビュー発火→原文 vs レビュー版を見比べ→採用する方を入力欄へデプロイ`。レビュー不要なら素通り（ただの音声入力）。多くの場合はレビューを参考に原文を少し直して使う想定。
   - 流用: 元 macOS 版の `ReviewPrompt` / 構造化スキーマ / `ReviewProvider`。
   - 実装: 自前契約 `BombSquadService`（`transcribe` / `review`）を固定 → v1 は BYOK 実装（Groq/OpenAI/Anthropic 直叩き、キーは Keychain Sharing）。レビューは背面アプリで実行しステージングへ流す。レビュー発火トリガー（Mac 版の右 Shift ダブルタップ相当）を iOS でどう割り当てるか要設計。
3. **シームレス化の磨き**：自動停止（無音検知）、戻り導線、UI。
4. **完全自動復帰の継続調査**：現時点では勝ち筋が見えていない。private API に依存せずに成立するか、OS アップデートや他実装例を引き続き監視する。
5. **受信側（transform / 見る→わかる→返す）**：**優先度低と判断（2026-07-04）**。スマホでは汎用チャット AI がスクショ説明を代替できてしまい、「自律的にフォームを埋める」レベルに届かない中間実装は使われない。iOS の価値提供点は入力の瞬間＝キーボード拡張に集中する。実現経路の選択肢マップ（スクショ駆動 / Safari Web Extension / Broadcast+PiP 等）と判断の根拠は [docs/receiving-side-options.md](docs/receiving-side-options.md) に整理済み。波が来た時に再評価。

---

## 9. 補足

- ドキュメントは日本語、コード内コメントは英語（UTF-8 エンコーディング事故回避のため）。
- 設計の根拠（WhisperFlow の分解、iOS 制約の一次情報、競合）は [docs/research-findings.md](docs/research-findings.md)。
