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
                }
        }
    }
}
