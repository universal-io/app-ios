# iOSカスタムキーボード拡張と音声入力とLLM後処理アプリの実現可能性

## 先に結論

BOMB SQUAD の中核である「任意アプリの入力直前に、音声入力→文字起こし→LLM後処理→注入」を iOS で実現すること自体は、**技術的には可能**です。ただし、その実現形は「キーボード拡張が何でもできる」ではなく、**キーボード拡張は薄く、権限取得・設定導線・重い処理・一部の音声起動は主アプリに寄せる**というハイブリッド設計が現実的です。Apple 公式には、カスタムキーボードは Open Access でネットワークと共有コンテナを使え、現行 UIKit ドキュメントには「dictation を提供するキーボードなら `hasDictationKey` を使う」と明記があります。一方、Apple の旧 App Extension Programming Guide には「custom keyboard は microphone にアクセスできない」と残っており、**公式一次情報の中でも時代差による不整合**があります。したがって、音声入力については「現行 OS で実動するが、設計・権限・審査説明が重要」という整理が妥当です。 citeturn38view0turn34search0turn44view0turn32search0turn45view0

Wispr Flow の iPhone 実装は、公開情報からみる限り**完全な“キーボード単独完結”ではなく、主アプリを絡めたハイブリッド**です。Wispr のヘルプは、**キーボード拡張は iOS の permission dialog を直接出せないので、マイク権限プロンプトは主アプリから出す必要がある**と明言しています。さらに 9to5Mac の実地レビューでは、キーボード上の “Start Flow” を押すと **いったん主アプリへ飛んで Flow Session を有効化し、元のアプリへ戻る**と報じられています。つまり、少なくとも**初回権限付与とセッション開始の一部は container app 側**です。 citeturn40search1turn39search0turn31view0turn10view4

製品戦略としては、**iOS 26 以上を狙うなら Apple SpeechAnalyzer / SpeechTranscriber を第一候補**にし、**iOS 18 系まで広く取りにいくならリモート ASR を併用した二層戦略**が最も現実的です。理由は単純で、Apple の新 SpeechTranscriber は**モデルがシステム側メモリで動き、アプリの実行時メモリを増やさない**と WWDC で説明されており、キーボード拡張の苛烈なメモリ制約と非常に相性がよいからです。逆に whisper.cpp をキーボード拡張内で回す案は、メモリと起動時間の両面で厳しく、**やるなら主アプリ側**です。 citeturn16view0turn17view0turn17view1

## カスタムキーボード拡張の能力と制約

**Full Access と RequestsOpenAccess**  
**結論**: `RequestsOpenAccess = YES` は、キーボード拡張を“デフォルト sandbox”に近い側へ広げ、**ネットワーク通信**と**App Group 共有コンテナ**を実用可能にします。オフのままでは、Apple のセキュリティ文書どおり、**ネットワークやネットワーク代理サービス経由の外部送信をブロックする極めて制限的な sandbox**で動きます。アーカイブされた Apple ガイドでは、Open Access 時に共有コンテナ・Location Services・Address Book などの連携範囲が広がることも明示されています。 citeturn38view0turn1view0turn44view1turn32search0

**根拠と出典URL**: Apple Platform Security は、custom keyboard はデフォルトでネットワークやそれに準ずる exfiltration API が封じられ、Open Access を要求するとユーザー同意後に default sandbox で動くと説明しています。旧 Apple ガイドの Table 8-1 は、Open Access のオンで shared container と network access が有効になり、他の privacy-controlled 配下の機能も広がるとしています。 citeturn38view0turn1view0

**確度**: 高。Apple 公式同士で整合しています。 citeturn38view0turn1view0

**実装上の含意**: BOMB SQUAD で LLM API やサーバー ASR を呼ぶなら、**Full Access は必須**です。同時に、審査では「Full Access がないと何ができないか」「入力内容を何のために送るか」「保存するか否か」を極めて明快に説明する必要があります。さらに、**Full Access なしでも最低限の typed input は成立**させるべきで、これは App Review Guideline 4.4.1 の “Remain functional without full network access and without requiring full access” に直結します。 citeturn45view0turn46view2turn38view0

**キーボード拡張からのマイクと音声録音**  
**結論**: この論点は Apple 公式の時代差で最も割れています。旧 Apple ガイドは「custom keyboards have no access to the device microphone」と書いていますが、現行 UIKit ドキュメントは**「dictation を提供するキーボードなら `hasDictationKey` を true にする」**と案内しています。加えて、Wispr Flow は iPhone で実際に音声キーボードを提供しており、少なくとも**現在の iOS では“音声つき第三者キーボード”は実在し、審査も通っています**。ただし、**permission dialog はキーボード拡張から直接は出せない**ため、マイク権限の初回取得は主アプリから行う必要があります。 citeturn44view0turn34search0turn40search1turn10view3

**根拠と出典URL**: 旧 Apple ガイドは iOS 8 時代の制約として microphone 不可を明記しています。一方、現行 UIKit の検索スニペットは、dictation を提供する custom keyboard で `hasDictationKey` を使うよう示しています。Wispr のヘルプは、**「Keyboard extensions can't trigger iOS permission dialogs directly, so the prompt has to come from the main app.」**と説明し、さらに iPhone では keyboard mic で dictation できることをセットアップ手順に含めています。9to5Mac も Wispr Flow のキーボードから “Start Flow” で主アプリへ短く遷移して戻る挙動を記述しています。 citeturn44view0turn34search0turn40search1turn31view0turn10view4

**確度**: 中。  
現行 iOS での**実動**は高確度ですが、**「録音そのものが extension process 内か、container app handoff か」**の切り分けは公開情報だけでは確定できません。Apple 公式文書が古いものと新しいものの間で不整合を含むためです。 citeturn44view0turn34search0turn40search1

**実装上の含意**: BOMB SQUAD は、**初回マイク permission 取得を主アプリで完了させる前提**にすべきです。そのうえで、キーボード側は mic タップ時に「未許可なら app へ誘導、許可済みなら dictation 開始」という二段分岐を持つべきです。`NSMicrophoneUsageDescription` は主アプリ側に必須で、Purpose String は「音声を文字起こしし、任意アプリへ挿入するため」と明示すべきです。`AVAudioSession` をどこで持つかは未確認要素が残るため、**初期実装は“権限取得と回復導線は主アプリ、入力 UI と注入はキーボード”の 안전側設計**が推奨です。 citeturn40search1turn31view0turn16view0turn46view3

**Wispr Flow がどこで録音しているか**  
**結論**: **少なくとも初回またはセッション開始の一部は主アプリ handoff**です。これ自体は 9to5Mac のレビューと Wispr の Action Button ヘルプが一致しています。その後の継続録音が**完全に extension process なのか、主アプリのセッション継続なのかは未確認**です。 citeturn10view4turn39search1turn40search1

**根拠と出典URL**: 9to5Mac は、「Start Flow を third-party keyboard から押すと full-blown app に行って Flow Session を activate し、元アプリに戻る」と具体的に記述しています。Wispr の Action Button ヘルプも「Apple requires Flow to briefly switch apps to activate the microphone」と書いています。さらに Wispr は「permission prompt は main app から」と明言しています。 citeturn10view4turn39search1turn40search1

**確度**: 高。  
ただし「その後の録音継続主体」までは中以下です。 citeturn10view4turn39search1turn40search1

**実装上の含意**: BOMB SQUAD も、**“セッション開始だけ app で起こし、その後 keyboard 側で利用する”**という設計が最も模倣しやすいです。UX 上はやや煩雑でも、iOS の permission / scene 制約に自然に沿います。 citeturn10view4turn31view0turn40search1

**メモリ上限とクラッシュ挙動**  
**結論**: Apple は**数値上限を公式に公開していません**が、「超過すると system terminates the extension」は公式文書に明記しています。実測・開発者報告では、**おおむね数十 MB 台**で非常にシビアです。2026 年の Apple Developer Forums 投稿では custom keyboard の memory cap を **約 30–48 MB** と表現しており、別の開発者記事では 30MB 付近から増え続け **70MB で kill** された事例が報告されています。 citeturn18search7turn21view0turn20view1

**根拠と出典URL**: 公式 documentation snippet は「memory limit を超えると system terminates」と説明しています。非公式ながら、Apple Developer Forums の 2026 投稿は voice dictation keyboard を前提に 30–48MB を前提条件としており、Medium の 2026 記事は launch 30MB・リークで 70MB 到達時 kill・改善後 20MB 前後安定という実測を示しています。 citeturn18search7turn21view0turn20view1

**確度**: 中。  
“超過時 terminate” は高確度、**数値**は実測ベースでデバイス・OS 差が大きいです。 citeturn18search7turn21view0turn20view1

**実装上の含意**: キーボード拡張には、**Whisper 本体・大きな LLM・WebView・重い画像資産**を持ち込まない方がよいです。UI は軽量、状態は最小、モデルは主アプリまたはサーバーへ逃がす、リークを厳しく監視する、という方針が必須です。特に SwiftUI + 依存注入 + closure retain cycle は危険です。 citeturn20view1turn21view0turn16view0

**UITextDocumentProxy の能力と限界**  
**結論**: `UITextDocumentProxy` は**挿入・削除・カーソル近傍コンテキスト取得**には使えますが、**編集中フィールド全文の読み出し API ではありません**。Apple 公式も “near the insertion point” と表現しており、キーボードは**テキスト選択もできません**。secure field・phone pad・custom keyboard 禁止アプリでは使えません。 citeturn22search11turn44view2turn44view0turn44view1

**根拠と出典URL**: Apple の archived custom keyboard guide は `documentContextBeforeInput` を「insertion point 近傍の textual context」と説明し、`insertText:`, `deleteBackward`, `adjustTextPositionByCharacterOffset:` の利用例を示しています。同じ文書で secure text field・phone pad・アプリ側の `application:shouldAllowExtensionPointIdentifier:` による custom keyboard 禁止を明示しています。また「cannot select text」と明記されています。 citeturn44view2turn44view0turn44view1turn44view4

**確度**: 高。 citeturn44view2turn44view0

**実装上の含意**: BOMB SQUAD の「トゲ取り・誤字修正・構造化」は、**“いま入力しようとしているテキスト塊”を自前でキーボード側バッファとして持つ設計**が基本になります。受信側テキストや入力欄全文を読み直して LLM 編集する、という設計は iOS キーボード API に乗りません。つまり、**send 前の compose buffer を自前で保持して一括注入する UX**の方が安定します。 citeturn44view2turn44view4turn22search0

**HTTPS 通信のレイテンシと落とし穴**  
**結論**: キーボード拡張からの HTTPS は可能ですが、**Full Access 前提**であり、拡張プロセスの寿命・メモリ・非同期化・ネットワーク品質の影響を強く受けます。長時間処理を extension 直結で抱えるほど不安定さが増えます。 citeturn38view0turn26view0turn23view0turn40search5

**根拠と出典URL**: Apple Platform Security は default sandbox で network を遮断し、Open Access で default sandbox 相当に拡張すると記します。App Extension Programming Guide は、background upload/download を使う場合は**共有コンテナが必須**とし、`NSURLSessionConfiguration.sharedContainerIdentifier` を案内しています。WWDC23 では iOS 17 以降 keyboard が out-of-process・非同期初期化になったことが説明されています。Wispr のトラブルシューティングも “Poor connection” を主要失敗要因として扱っています。 citeturn38view0turn26view0turn23view0turn40search5

**確度**: 高。 citeturn38view0turn26view0turn23view0

**実装上の含意**: LLM 後処理は、**短いテキスト断片を小さな JSON で投げる**こと、**タイムアウトと再試行を簡潔に**すること、**キーボードが落ちてもユーザー入力が失われない compose buffer**を App Group に退避することが重要です。長い音声ファイル upload や重い streaming state machine は、キーボード拡張より主アプリ側の責務に寄せるべきです。 citeturn26view0turn23view0turn21view0

## Wispr Flow と競合の実装構造

**Wispr Flow のオンボーディングフロー**  
**結論**: Wispr Flow の iOS 導線はかなり明瞭で、**アプリ内オンボーディング → Go to Settings → キーボード追加・Full Access → チュートリアル → 初回 dictation で mic 権限 → 利用開始**です。これは BOMB SQUAD がそのまま参照できるレベルで具体的です。 citeturn31view0turn30search1turn40search9

**根拠と出典URL**: Wispr Help Center の Setup Guide は、iOS 手順として sign-in 後に “Enable the Flow Keyboard” を置き、「Go to Settings」で keyboard settings を開き、Flow keyboard 有効化と Full Access を案内し、その後 keyboard walkthrough と mic の “Try It Yourself” を行うと記載しています。別記事でも「Settings → General → Keyboard → Keyboards → Flow → Allow Full Access」を明示しています。 citeturn31view0turn30search1turn30search12

**確度**: 高。 citeturn31view0turn30search1

**実装上の含意**: BOMB SQUAD も、**“主アプリが setup coach、キーボードは execution surface”**という役割分担にした方がよいです。権限、Full Access、マイク、期待 UX の教育は主アプリで完了させるべきです。 citeturn31view0turn40search1

**Settings へのディープリンク**  
**結論**: 公開 API で安全なのは **`UIApplication.openSettingsURLString` で自アプリ設定を開くことだけ**です。キーボード設定へ直接飛ばす `prefs:` は、Apple が 2016 年に keyboard extension 限定で例外説明したものの、**retired legacy document**です。`App-Prefs:` 全般は公開 API ではなく、**レビューリスクが高い**です。現時点で Wispr がどのスキームを使っているかは**未確認**です。 citeturn28view0turn27search0turn27search5turn45view0

**根拠と出典URL**: Apple の `openSettingsURLString` は “your app's custom settings” を開くための official API です。QA1924 は keyboard extension から `prefs:root=General&path=Keyboard` を使う例を載せつつ、**それ以外の undocumented use は App Review Guidelines 違反になり得る**と書いていますが、同文書自体が retired / legacy 扱いです。 Guideline 2.5.1 は public API のみ使用を要求しています。 citeturn28view0turn27search0turn27search5turn45view0

**確度**: 高。  
ただし“現行 iOS で実際にどの undocumented URL が動くか”は未確認です。 citeturn28view0turn27search0turn45view0

**実装上の含意**: App Store 安全策としては、**自アプリ設定へは official deep link、キーボード設定へは画面コーチング＋手順ガイド**が基本です。もし `prefs:` を使うなら、**keyboard extension 限定・キーボード設定限定**に留める以外の安全な言い訳は見当たりませんが、それでも legacy 依存です。BOMB SQUAD の本番設計では、これを**必須導線にしない**方がよいです。 citeturn28view0turn45view0

**“オーバーレイで案内”の正体**  
**結論**: Wispr の公開資料から確認できるのは、**「on-screen walkthrough」や「keyboard walkthrough cards」**であり、iOS 全画面の system overlay を使っている一次情報は見当たりません。したがって、公開情報ベースでは**自前コーチング UI**とみるのが妥当です。 citeturn31view0

**根拠と出典URL**: Setup Guide は “Watch the on-screen walkthrough” “keyboard walkthrough cards” と表現しており、Accessibility overlay や system-wide overlay API を示していません。iOS では Android のような恒常的 “display over other apps” 権限もありません。 citeturn31view0turn30search3

**確度**: 中。  
“真の overlay ではない”はかなり妥当ですが、実装内部は未公開です。 citeturn31view0turn30search3

**実装上の含意**: BOMB SQUAD も、**設定遷移の直前にフルスクリーンの coach mark を出す**程度が現実的です。iOS の system overlay 前提の UX は置かない方がよいです。 citeturn31view0

**Wispr Flow のアーキテクチャ推定**  
**結論**: Wispr は少なくとも現在、**クラウド ASR / クラウド LLM 中心**です。公式 Data Controls は **“Transcription always occurs on the cloud”** と明言しており、9to5Mac には **OpenAI Whisper と Meta Llama の mix** とあります。料金体系は free tier と Pro / Enterprise のサブスクで、iPhone 無料枠は週 1,000 words、Pro は無制限です。 citeturn11search0turn10view4turn11search1turn11search6

**根拠と出典URL**: Wispr Data Controls は「transcription always occurs on the cloud」「third-party AI providers とは zero data retention agreements」と明示します。Pricing は free / Pro / Enterprise を提示し、iPhone の free 枠を含む word cap を載せています。9to5Mac は Wispr からの説明として、OpenAI Whisper と Meta Llama の mix を報じています。 citeturn11search0turn10view4turn11search1turn11search6

**確度**: 高。  
モデル構成の細部は二次情報ですが、**クラウド transcription**は一次情報です。 citeturn11search0turn10view4

**実装上の含意**: BOMB SQUAD も、品質優先なら **初期は cloud-first** が現実的です。ただし、あなたのプロダクトは「トゲ取り」というセンシティブな文意変換を扱うため、**Privacy Mode・保存無効・短期 retention・企業向け zero retention 契約**を製品要件に最初から入れるべきです。 citeturn11search0turn46view3

**同種競合と市場の成熟度**  
**結論**: 2025–2026 の iPhone 市場では、**Wispr Flow、Aqua Voice、Superwhisper、Typeless** など、すでに「AI voice keyboard / dictation in any app」を訴求する競合が複数存在します。したがって、このカテゴリはもはや未開拓ではなく、**“レッドオーシャン化の入口”**にあります。差別化余地は、単なる ASR 精度よりも、**送信前 LLM 後処理の品質、プライバシー保証、Slack/Gmail 向けのトーン制御、受信文への補助導線**にあります。 citeturn10view3turn12search4turn13search3turn13search12

**根拠と出典URL**: Aqua Voice は iPhone 向け App Store で “AI Voice Keyboard” として、どの app でも speech-to-text と訴求しています。Superwhisper は “in whatever app you're using” で polished text を謳い、サイトでは cloud / local model・BYOK を打ち出しますが、セキュリティ文書では local language models は現在 macOS only としています。Typeless も iPhone 専用 AI voice keyboard として流通しています。 citeturn12search4turn13search3turn14search1turn14search4turn13search12

**確度**: 高。 citeturn12search4turn13search3turn13search12

**実装上の含意**: BOMB SQUAD の訴求軸は、**“声で書ける”ではなく“送る前に人間関係コストを下げる”**に置くべきです。つまり ASR 製品ではなく、**コミュニケーション safety layer**として設計・命名・審査説明を揃える方が勝ち筋です。 citeturn10view3turn12search4turn13search3

## App Store 審査リスク

**Full Access とマイクとネットワーク送信の組み合わせ**  
**結論**: これは審査上もっとも敏感な構成です。ただし、**不可能ではなく、条件付きで通る構成**です。Apple の Guideline 4.4.1 は keyboard extension について、**typed input 機能を提供すること、次キーボード遷移を持つこと、Full Access なしでも機能すること、収集データは keyboard の機能強化に限ること**を要求しています。加えて 5.1.1 は privacy policy・明示的説明・同意撤回導線を求めます。 citeturn45view0turn46view1turn46view3

**根拠と出典URL**: App Review Guidelines 4.4.1 は keyboard extensions の追加ルールを明示し、5.1.1 は privacy policy の内容と permission の扱いを具体的に規定しています。App Privacy Details と App Store Connect Help は、**自社だけでなく third-party partners のデータ収集も含めて App Privacy に申告する義務**を繰り返しています。 citeturn45view0turn46view3turn42search0turn42search3

**確度**: 高。 citeturn45view0turn46view3turn42search3

**実装上の含意**: 申請時には、少なくとも次を準備すべきです。  
第一に、**キーボードが収集するデータの完全な棚卸し**です。音声、転写文、プロンプト、修正文、辞書、エラーログ、分析イベントを分けて説明してください。第二に、**Privacy Nutrition Label を厳密に記述**してください。第三に、**App Review Notes に reviewer 用のセットアップ手順**を詳述し、Full Access・マイク・テストアカウント・サンプル入力を提供してください。第四に、**「キーボードは送信ボタンを押す前にユーザーの意思で文面を整える」という利用目的**をプライバシーポリシー・オンボーディング・権限文言で一致させてください。 citeturn45view0turn46view3turn42search2turn42search3

**過去のリジェクト筋**  
**結論**: 典型的な reject 筋は、**private API / undocumented settings URL**、**説明不足のデータ送信**、**Full Access なしで実質使えない導線**、**キーボードなのに keyboard input 以外が主目的に見える実装**です。審査で一番危ないのは、`App-Prefs:` 系 deep link と、「何を外部送信するか曖昧な privacy 説明」です。 citeturn28view0turn45view0turn46view3

**根拠と出典URL**: QA1924 は `prefs:` の use をごく限定例外として扱いつつ、一般利用は App Review 違反になり得ると書いています。Guideline 2.5.1 は public APIs only を明確に要求し、Guideline 5.1.1 は収集データと利用法の明確化を要求します。 citeturn28view0turn45view0turn46view1

**確度**: 高。 citeturn28view0turn45view0

**実装上の含意**: 審査通過確率を上げるなら、**“BOMB SQUAD は送信前の文面磨きキーボード”と一貫して見せる**ことです。会議録音アプリ、バックグラウンド常駐録音アプリ、見えないところで常時集音するアプリ、という印象を与えると危険です。マイクは**押している間だけ**または**明確な開始・停止 UI**を持ち、常時録音に見える挙動は避けるべきです。 citeturn45view0turn46view2turn10view4

## 推奨アーキテクチャ

**主アプリとキーボード拡張と共有領域**  
**結論**: ベストプラクティスは **App Group 中心**です。Apple は extension と containing app が互いの container へ直接アクセスできない一方、**App Group の shared container と suite-based UserDefaults** を使えば共有できるとしています。shared container 上のファイル共有では、**Core Data / SQLite / POSIX lock / NSFileCoordinator** 等で整合性を取るべきです。秘密情報は必要に応じて **Keychain Sharing** を併用します。 citeturn26view0turn24search16turn24search0turn24search1

**根拠と出典URL**: App Extension Programming Guide は shared container を App Groups で設定し、`initWithSuiteName:` による shared defaults を案内しています。また background `NSURLSession` を extension から使う場合は shared container が必須と明記しています。Apple の keychain documentation は、App Groups / access groups により keychain 共有が可能と説明します。 citeturn26view0turn24search16turn24search0turn24search1

**確度**: 高。 citeturn26view0turn24search16

**実装上の含意**: BOMB SQUAD は、  
認証トークンや refresh token は **Keychain Sharing**、  
compose buffer・未送信草稿・軽量設定は **App Group UserDefaults / small file**、  
長めの transcript や job state は **App Group SQLite**、  
という分離がよいです。Darwin notification や polling は補助で使えますが、**単一真実源は shared storage** に置くべきです。 citeturn26view0turn24search0turn24search1

**ASR の選択肢比較**  
**結論**: 推奨順位は、  
**iOS 26+ 限定なら Apple SpeechAnalyzer / SpeechTranscriber が第一候補**、  
**iOS 18–25 も狙うなら Apple Speech + remote ASR の併用**、  
**whisper.cpp は主アプリ限定なら検討余地、キーボード拡張内は非推奨**、  
という順です。 citeturn16view0turn17view0turn17view1turn11search0

**根拠と出典URL**: WWDC25 で Apple は SpeechTranscriber を**on-device・低遅延・長尺対応**とし、さらに**モデルは app memory space の外で動き runtime memory size を増やさない**と説明しています。WWDC19 は `SFSpeechRecognizer` の on-device recognition を説明し、WWDC23 は custom language model も on-device で使えるとしています。一方、Wispr は accuracy と low latency のため **cloud transcription** を選んでいます。 citeturn16view0turn17view0turn17view1turn11search0

**確度**: 高。 citeturn16view0turn17view0turn17view1

**実装上の含意**:  
iOS 26 専用に寄せられるなら、**Apple 純正 ASR + 自前 LLM 後処理**がもっともきれいです。ASR メモリが app 側に乗りにくいため、keyboard extension 制約とも相性が良いからです。  
iOS 18 対応が要るなら、**短文は remote ASR、長文や privacy priority は主アプリ on-device、キーボードは軽量化**という二段構えが現実的です。  
whisper.cpp を keyboard extension に入れるのは、メモリ・起動・バッテリーの三重苦になりやすいので避けるべきです。 citeturn16view0turn17view0turn21view0turn20view1

**ストリーミング対応**  
**結論**: Apple 純正では、SpeechAnalyzer が**volatile result と finalized result**を伴う live transcription に対応します。SFSpeechRecognizer も live audio 認識に使えます。したがって、「話しながら UI 上に暫定文を表示し、確定後に LLM polishing」は設計可能です。 citeturn16view0turn17view0turn16view5

**根拠と出典URL**: WWDC25 は AsyncSequence ベースで audio input と result stream を分離し、volatile / finalized transcript の扱いまで説明しています。WWDC19 と Apple tutorial も live audio recognition を前提にしています。 citeturn16view0turn17view0turn16view5

**確度**: 高。 citeturn16view0turn17view0

**実装上の含意**: BOMB SQUAD に最も向くのは、**ASR は逐次表示、LLM は stop/confirm 時点だけ回す**構成です。常時 LLM streaming まで keyboard 内でやると遅延とコストが跳ねやすいので、まずは**最終確定直前の一発 polishing**から始めるのがよいです。 citeturn16view0turn11search1

## 受信側の読解支援とシステム横断の限界

**相手から届いた文章を取り込んで LLM 加工する手段**  
**結論**: iOS に**システム横断で他アプリの受信文を読み取る public API はありません**。現実的な手段は、**Share Extension / Action Extension / Safari Extension / ユーザーが選択したテキストの受け渡し**です。つまり、「受信メッセージを勝手に読んで要約」は無理で、「選択したテキストを BOMB SQUAD に渡して解釈支援」は可能、という整理が正しいです。 citeturn43search6turn43search3turn43search1turn43search17

**根拠と出典URL**: Apple の extension overview は、host app が extension request に**selected text**を含めて渡す例を示しています。Action extension は iOS の share sheet の action area から起動する形式です。Safari では Share / Action extension の JavaScript preprocessing や Safari Web Extension により、Web 上の選択テキストやページ内容へアクセスできます。逆に、どの文書にも「任意アプリの受信文をバックグラウンドで横断取得する」API は出てきません。 citeturn43search6turn43search3turn26view0turn43search17

**確度**: 高。 citeturn43search6turn43search3turn26view0

**実装上の含意**: BOMB SQUAD の受信側機能は、  
メール・チャットでは **選択テキスト共有**、  
Web では **Safari Extension / Action Extension**、  
アプリ内では **「貼り付けて解析」または OCR / Live Text 起点**、  
という UX に分けるのが現実的です。汎用 OS 層での“受信メッセージ自動読解”を企画の前提にしない方が安全です。 citeturn43search3turn43search17turn43search16

## BOMB SQUAD を作るうえでの最重要な技術的決定事項と致命的リスク

**BOMB SQUAD を作るうえでの最重要な技術的決定事項 TOP5**  
**結論**: もっとも重要なのは、**keyboard-first ではなく app-assisted keyboard** と割り切ることです。これを曖昧にすると、権限・メモリ・審査・UX のすべてで苦しくなります。 citeturn31view0turn40search1turn26view0turn21view0

第一に、**ターゲット OS をどこで切るか**です。iOS 26+ に寄せるなら Apple SpeechAnalyzer を軸にでき、メモリ問題が大きく楽になります。iOS 18 系まで広げるなら、ASR は remote 併用がほぼ必要です。 citeturn16view0turn17view0

第二に、**音声は session-based か push-to-talk か**です。Wispr のような session activation は高機能ですが、iOS の app round-trip 制約を背負います。最初は **press / hold か tap-to-start / tap-to-stop** の明示 UI の方が審査説明もしやすいです。 citeturn10view4turn39search1

第三に、**LLM 後処理の単位を “入力欄全文” でなく “自前 compose buffer” にする**ことです。UITextDocumentProxy 依存で全文編集を期待すると破綻しやすいです。 citeturn44view2turn44view4

第四に、**クラウド保存をデフォルトにするか、Privacy Mode をデフォルトにするか**です。Wispr が示すように cloud transcription は UX に効きますが、BOMB SQUAD はトーン調整というセンシティブ用途ゆえ、**保存オフ・学習利用オフ・短期 retention**を初期設計から積む価値が高いです。 citeturn11search0turn46view3

第五に、**審査説明をプロダクトの一部として設計する**ことです。keyboard extension は単なる実装ではなく、**信頼の UI**が製品要件です。Full Access の理由、送信先、保存の有無、レビュー用デモ導線まで設計に含めるべきです。 citeturn45view0turn46view3turn42search3

**致命的になりうるリスク**  
**結論**: 致命リスクは大きく三つです。**審査落ち、技術的な不安定、コスト過大**です。どれも事前の設計でかなり軽減できます。 citeturn45view0turn21view0turn11search1

第一の致命リスクは、**private API / undocumented Settings deep link 依存**です。`App-Prefs:` や一般化した `prefs:` を主導線にすると、2.5.1 リスクが高いです。 citeturn28view0turn45view0

第二は、**キーボード拡張に重い処理を積みすぎて kill されること**です。ASR、LLM、複雑な UI、リークの組み合わせは危険です。voice keyboard で 30–48MB 前提と考える開発者投稿や、70MB kill 事例は無視できません。 citeturn21view0turn20view1

第三は、**クラウド ASR / LLM の単価と待ち時間**です。音声→LLM polishing を every message で回すと、無料枠ではすぐ赤字化します。Wispr や Superwhisper が free / paid tiers を明確に分けているのは、この economics を反映しています。 citeturn11search1turn11search6turn14search1

第四は、**OS 仕様変更で主アプリ往復 UX が崩れること**です。2026 年の Apple Developer Forums には、iOS 26.4 以降で keyboard extension から container app に飛んだ後、元ホストアプリへ public API で確実に戻る方法が見当たらないという報告があります。これは BOMB SQUAD が app round-trip に強く依存する場合の将来リスクです。 citeturn21view0

第五は、**“受信文の読解支援”を OS 横断自動処理だと誤設計すること**です。これは public API のない領域なので、構想のまま作ると詰みます。選択テキスト共有ベースへ前提を落とす必要があります。 citeturn43search6turn43search3

## 未確認事項

**未確認**: 現行 iOS において、**custom keyboard extension process 自体が microphone capture をどこまで安定して担えるか**の Apple 一次情報は、旧資料と新資料が食い違っています。現行 UIKit は dictation 提供を前提にした記述がある一方、旧アーカイブは microphone 不可と書いています。実動アプリは存在しますが、**録音主体が extension なのか、container app の session handoff なのか**は公開情報だけでは断定できません。 citeturn44view0turn34search0turn40search1turn10view4

**未確認**: Wispr Flow の「Go to Settings」ボタンが、**`openSettingsURLString`、`prefs:`、あるいは単なる coach screen + manual navigation** のどれで実現されているかは、公開一次情報では確認できませんでした。Apple の安全な公開 API は自アプリ設定のみで、keyboard settings 直行は legacy / undocumented の領域です。 citeturn28view0turn27search0turn31view0

**未確認**: `documentContextBeforeInput / AfterInput` の**取得文字数上限の現行 iOS での公式数値**は確認できませんでした。Apple は “near the insertion point” としか案内しておらず、全文取得 API ではないことまでは高確度ですが、正確な文字数 cap は未確認です。 citeturn44view2turn22search13

**未確認**: キーボード拡張の**現行 iOS における公式メモリ上限数値**も未公開でした。数十 MB 台というのは実測・開発者報告ベースです。公式に確認できたのは「超過時に terminate される」点までです。 citeturn18search7turn21view0turn20view1