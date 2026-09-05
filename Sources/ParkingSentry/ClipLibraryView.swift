import SwiftUI
import AVKit

/// Recorded clips: watch them, share them, delete them.
struct ClipLibraryView: View {
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss
    @State private var playing: URL?

    var body: some View {
        NavigationStack {
            Group {
                if engine.clipURLs.isEmpty {
                    ContentUnavailableView("No recordings yet",
                        systemImage: "film",
                        description: Text("A clip is saved automatically each time something is detected, starting a few seconds before the trigger."))
                } else {
                    List {
                        ForEach(engine.clipURLs, id: \.self) { url in
                            Button { playing = url } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(for: url)).font(.headline)
                                    Text(subtitle(for: url))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { delete(url) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $playing) { url in
                VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
            }
        }
    }

    private func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let label = name.split(separator: "_").last.map(String.init) ?? "clip"
        return label.capitalized
    }

    private func subtitle(for url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return date.formatted(date: .abbreviated, time: .standard)
            + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        engine.clipURLs.removeAll { $0 == url }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
