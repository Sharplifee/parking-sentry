import SwiftUI
import UIKit

@main
struct ParkingSentryApp: App {
    @StateObject private var settings = Settings.shared
    @StateObject private var engine = DetectionEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    AlertManager.shared.requestNotificationPermission()
                    // Findable and streaming from launch: gating this on "armed"
                    // is why two paired devices saw each other but no picture.
                    PeerMesh.shared.start()
                    // Move the wall to a real second screen when one appears.
                    ExternalDisplayManager.shared.begin()
                }
        }
    }
}
