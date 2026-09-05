import SwiftUI
import UIKit
import AVFoundation

@main
struct ParkingSentryApp: App {
    @StateObject private var settings = Settings.shared
    @StateObject private var engine = DetectionEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Re-try every time the app comes forward: after a trip to
                    // Settings, after an interruption, after multitasking.
                    engine.startPreview()
                    PeerMesh.shared.start()
                }
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
