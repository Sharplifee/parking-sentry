import SwiftUI
import AVKit

struct ClipPlayerView: View {
    let url: URL
    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .ignoresSafeArea()
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
    }
}
