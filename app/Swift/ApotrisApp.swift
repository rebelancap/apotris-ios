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
                #if os(iOS)
                // iOS only: hides the home indicator. On visionOS this ALSO
                // hides the window's move pill / grab chrome, so scope it out —
                // that's why the grabber wouldn't appear on gaze.
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
                #endif
        }
        #if os(visionOS)
        // 3:2 to match the game's native content aspect. .automatic (not
        // .contentSize) so the window shows resize corners; the game scales its
        // fixed canvas to fill any size, so the gradient still covers the border.
        .defaultSize(width: 1020, height: 680)
        .windowResizability(.automatic)
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
