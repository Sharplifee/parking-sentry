import SwiftUI

/// Shown once, on first launch.
///
/// The app previously opened straight onto a black camera with an Arm button and
/// no indication that it is a two-device system — which is the single thing that
/// makes it useful and the single thing nobody would guess. This names the setup
/// and asks for the permissions up front, so the first run is not a black
/// rectangle and a permission prompt with no context.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mesh = MeshClient.shared
    @State private var name: String = MeshClient.shared.deviceName
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                pageOne.tag(0)
                pageTwo.tag(1)
                pageThree.tag(2)
            }
            .tabViewStyle(.page)

            Button(page < 2 ? "Next" : "Start watching") {
                if page < 2 { withAnimation { page += 1 } } else { finish() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.green, in: Capsule())
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.bottom, 26)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .interactiveDismissDisabled()
    }

    private var pageOne: some View {
        info(icon: "viewfinder",
             title: "One device watches",
             body: "Prop a device where you want eyes — the far end of a lot, a doorway, your office. Tap Arm and it watches for people, vehicles, animals and anything else that moves.\n\nShadows, headlights and blowing debris are filtered out before an alert can fire.")
    }

    private var pageTwo: some View {
        info(icon: "iphone.and.arrow.forward",
             title: "Another device watches it",
             body: "Open MotionSentry on a second device and they find each other automatically — no account, no setup, no internet needed.\n\nYou'll see its live camera, what it's detecting, how far away and how fast. Hold a camera tile to talk through it.")
    }

    private var pageThree: some View {
        VStack(spacing: 22) {
            Image(systemName: "tag").font(.system(size: 52)).foregroundStyle(.green)
            Text("Name this device").font(.title2.bold())
            Text("You'll see this name on your other devices when it detects something.")
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            TextField("Office iPad", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
            Text("MotionSentry needs the camera to watch, and the microphone for sound alerts and talk-back. Nothing leaves your devices.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .padding(.top, 40)
    }

    private func info(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 22) {
            Image(systemName: icon).font(.system(size: 52)).foregroundStyle(.green)
            Text(title).font(.title2.bold())
            Text(body)
                .font(.callout).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 40)
    }

    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != mesh.deviceName {
            PeerMesh.shared.renamed(to: trimmed)
        }
        UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        AlertManager.shared.requestNotificationPermission()
        DetectionEngine.shared?.startPreview()
        dismiss()
    }
}
