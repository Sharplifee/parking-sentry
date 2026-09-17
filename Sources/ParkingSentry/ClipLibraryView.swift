import SwiftUI
import AVKit

/// Recorded clips: watch them, share them, delete them.
struct ClipLibraryView: View {
    @EnvironmentObject var engine: DetectionEngine
    @Environment(\.dismiss) private var dismiss
    @State private var playing: URL?
    @State private var storage: (used: Int64, free: Int64, count: Int) = (0, 0, 0)

    var body: some View {
        NavigationStack {
            Group {
                if engine.clipURLs.isEmpty {
                    ContentUnavailableView("No recordings yet",
                        systemImage: "film",
                        description: Text("A clip is saved automatically each time something is detected, starting a few seconds before the trigger."))
                } else {
                    List {
                        Section {
                            let r = storage
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ByteCountFormatter.string(fromByteCount: r.used, countStyle: .file)
                                         + " in \(r.count) recordings")
                                        .font(.subheadline.weight(.semibold))
                                    Text(ByteCountFormatter.string(fromByteCount: r.free, countStyle: .file)
                                         + " free on this device")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { deleteAll() } label: {
                                    Text("Delete all").font(.caption)
                                }
                            }
                            Text("Oldest recordings are removed automatically once the keep-limit in Settings is reached.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
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
            .onAppear { storage = ClipRecorder.storageReport() }
            .safeAreaInset(edge: .bottom) {
                if !engine.clipURLs.isEmpty {
                    HStack {
                        Text("\(engine.clipURLs.count) clips")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: ClipRecorder.storageUsed(),
                                                       countStyle: .file))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
            }
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
        storage = ClipRecorder.storageReport()
    }

    private func deleteAll() {
        ClipRecorder.deleteAll()
        engine.clipURLs.removeAll()
        storage = ClipRecorder.storageReport()
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
