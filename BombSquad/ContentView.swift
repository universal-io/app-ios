import SwiftUI
import UIKit

/// Minimal host screen for Milestone 1.
/// - Explains how to enable the BOMB SQUAD keyboard.
/// - Provides a live text field so the keyboard can be tested immediately.
struct ContentView: View {
    let speech: SpeechService
    @Binding var cameFromKeyboard: Bool
    @State private var testText: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if shouldShowReturnGuide {
                    activationReturnScreen
                } else {
                    mainContent
                }
            }
            .navigationTitle(shouldShowReturnGuide ? "" : "BOMB SQUAD")
        }
    }

    private var mainContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if cameFromKeyboard {
                        Label("キーボードから録音を開始しました", systemImage: "keyboard.badge.ellipsis")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }

                    speechCard

                    if cameFromKeyboard && speech.status == .idle && !speech.transcript.isEmpty {
                        Label("元のアプリに戻ると、この内容が入力欄に貼り付けられます", systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }

                    setupSteps

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ここで試す")
                            .font(.headline)
                        TextField("BOMB SQUAD キーボードに切り替えて入力…", text: $testText, axis: .vertical)
                            .lineLimit(3...6)
                            .textFieldStyle(.roundedBorder)
                            .focused($fieldFocused)
                    }

                    Button {
                        // Public, App Store-safe deep link: opens THIS app's
                        // settings page. Keyboard settings are reached from
                        // there by the user (no private prefs: URL).
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("設定アプリを開く", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
    }

    private var activationReturnScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.green)

            VStack(spacing: 10) {
                Text("録音中")
                    .font(.largeTitle.bold())

                Text("元のアプリに戻って話してください")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Label("左上の ‹ アプリ名 を押す", systemImage: "arrow.left")
                Label("または、下のバーを右へスワイプ", systemImage: "arrow.right")
            }
            .font(.headline)
            .foregroundStyle(.primary)

            Spacer()

            Text("戻るとキーボードが入力欄へ反映します")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var speechCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("音声入力テスト")
                    .font(.headline)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.5))
                if speech.transcript.isEmpty {
                    Text(speech.status == .listening ? "話してください…" : "マイクを押して話す")
                        .foregroundStyle(.tertiary)
                        .padding(12)
                }
                // Finalized text in primary color, volatile hypothesis dimmed.
                (Text(speech.finalizedText) + Text(speech.volatileText).foregroundColor(.secondary))
                    .padding(12)
            }
            .frame(minHeight: 96, alignment: .topLeading)

            Button {
                Task { await speech.toggle() }
            } label: {
                Label(speech.status == .listening ? "停止" : "話す",
                      systemImage: speech.status == .listening ? "stop.circle.fill" : "mic.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(speech.status == .listening ? .red : .accentColor)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusLabel: String {
        switch speech.status {
        case .idle: return ""
        case .preparing: return "準備中…"
        case .listening: return "認識中"
        case .denied: return "マイク許可が必要"
        case .unavailable(let m): return m
        }
    }

    private var shouldShowReturnGuide: Bool {
        cameFromKeyboard && (speech.status == .preparing || speech.status == .listening)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("コミュニケーションの中間レイヤー")
                .font(.title3).bold()
            Text("送る前に一拍おく。まずはキーボードを有効化してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("有効化の手順")
                .font(.headline)
            step(1, "設定 → 一般 → キーボード → キーボード")
            step(2, "「新しいキーボードを追加」→ BOMB SQUAD を選択")
            step(3, "入力欄で🌐を長押しして BOMB SQUAD に切り替え")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption).bold()
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    ContentView(speech: SpeechService(), cameFromKeyboard: .constant(false))
}
