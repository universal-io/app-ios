import SwiftUI

/// Host application. Owns the dictation coordinator and reacts to the
/// `bombsquad://record` deep link the keyboard uses for the one-time activation.
@main
struct BombSquadApp: App {
    @State private var coordinator = DictationCoordinator()
    @State private var cameFromKeyboard = false

    var body: some Scene {
        WindowGroup {
            ContentView(speech: coordinator.speech, cameFromKeyboard: $cameFromKeyboard)
                .onOpenURL { url in
                    guard url.scheme == "bombsquad", url.host == "record" else { return }
                    cameFromKeyboard = true
                    coordinator.activateFromKeyboard()
                }
        }
    }
}
