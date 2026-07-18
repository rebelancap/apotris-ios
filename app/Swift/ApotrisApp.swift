import SwiftUI

@main
struct ApotrisApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = PortSettings()

    init() {
        Bridge.startGame()
        GameControllerManager.shared.activate()
        HapticsManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            GameScreen()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                #if os(iOS)
                .statusBarHidden()
                #endif
        }
        #if os(visionOS)
        // 3:2 to match the game's native content aspect, so it fills the
        // window with only a small even gradient border (no wide yellow sides).
        .defaultSize(width: 1020, height: 680)
        .windowResizability(.contentSize)
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                Bridge.requestSave()
                Bridge.setBackground(true)
            case .inactive:
                Bridge.requestSave()
            case .active:
                Bridge.setBackground(false)
            @unknown default:
                break
            }
        }
    }
}
