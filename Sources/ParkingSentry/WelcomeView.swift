import SwiftUI

/// Shown once, on first launch.
///
/// Three things this has to do, in this order: say what the app is for, name the
/// two-device setup that nobody would guess, and say that the layers exist. The
/// layers are the whole app and they are off by default, so an operator who never
/// opens that panel is running a motion sensor and wondering what the fuss is.
///
/// It also used to tell people to "tap Arm", a button that has not existed since
/// the camera screen was rebuilt. Onboarding that describes a version of the app
/// the user is not holding is worse than none.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mesh = MeshClient.shared
    @State private var name: String = MeshClient.shared.deviceName
    @State private var page = 0

    private let lastPage = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                pageOne.tag(0)
                pageTwo.tag(1)
                pageThree.tag(2)
                pageFour.tag(3)
            }
            .tabViewStyle(.page)

            Button(page < lastPage ? "Next" : "Start watching") {
                if page < lastPage { withAnimation(.snappy) { page += 1 } } else { finish() }
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.green.gradient, in: Capsule())
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
             body: "Prop a device where you want eyes — the far end of a lot, a doorway, your office. Press Start watching and it watches for people, vehicles, animals and anything else that moves.\n\nShadows, headlights and blowing debris are filtered out before an alert can fire.")
    }

    private var pageTwo: some View {
        info(icon: "square.stack.3d.up",
             title: "Switch on what you need",
             body: "Underneath the camera is a shelf of things it can do — read plates, recognise a face as one it has seen before, transcribe speech, count crossings of a line you draw, flag someone loitering.\n\nThey are all off until you turn them on, and each one shows what it costs. Start with a preset: Parking lot, Doorway, Night watch.")
    }

    private var pageThree: some View {
        info(icon: "iphone.and.arrow.forward",
             title: "Another device watches it",
             body: "Open MotionSentry on a second device and they find each other automatically — no account, no setup, no internet needed.\n\nYou'll see its live camera, what it's detecting, how far away and how fast. Hold a camera tile to talk through it.")
    }

    private var pageFour: some View {
        VStack(spacing: 20) {
            Image(systemName: "tag")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.green)
            Text("Name this device").font(Style.title)
            Text("You'll see this name on your other devices when it detects something.")
                .font(Style.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            TextField("Office iPad", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
            Text("MotionSentry needs the camera to watch, and the microphone for sound alerts and talk-back. Recordings stay on your devices unless you share them.")
                .font(Style.footnote)
                .foregroundStyle(.white.opacity(Style.dim))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 36)
    }

    private func info(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.green)
            Text(title).font(Style.title)
            Text(body)
                .font(Style.body)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
        }
        .padding(.top, 36)
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
