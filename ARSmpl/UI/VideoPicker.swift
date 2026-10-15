import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PickedVideo: Sendable, Equatable {
    let url: URL
    let name: String
}

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) }
            importing: { received in VideoFile(url: try Self.copyIn(received.file)) }
        FileRepresentation(contentType: .mpeg4Movie) { SentTransferredFile($0.url) }
            importing: { received in VideoFile(url: try Self.copyIn(received.file)) }
        FileRepresentation(contentType: .quickTimeMovie) { SentTransferredFile($0.url) }
            importing: { received in VideoFile(url: try Self.copyIn(received.file)) }
    }

    static func copyIn(_ src: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gemx_videos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
        let dst = dir.appendingPathComponent("\(UUID().uuidString.prefix(8)).\(ext)")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}

struct VideoPickerButton: View {
    @Binding var picked: PickedVideo?
    var onError: (String) -> Void = { _ in }

    @State private var photosItem: PhotosPickerItem? = nil
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var importing = false

    var body: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
            if picked != nil {
                Button(role: .destructive) { picked = nil } label: { Label("Clear", systemImage: "xmark.circle") }
            }
        } label: {
            HStack(spacing: 8) {
                if importing {
                    ProgressView().tint(.white).controlSize(.small)
                } else {
                    Image(systemName: picked == nil ? "video.badge.plus" : "video.fill")
                }
                Text(picked?.name ?? "Choose video")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").opacity(0.6).font(.caption)
            }
            .font(.system(size: 15, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassFieldStyle()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photosItem, matching: .videos)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let copy = try VideoFile.copyIn(url)
                    picked = PickedVideo(url: copy, name: url.lastPathComponent)
                } catch {
                    onError("Could not import video: \(error.localizedDescription)")
                }
            case .failure(let error):
                onError("Could not open video: \(error.localizedDescription)")
            }
        }
        .onChange(of: photosItem) { _, item in
            guard let item else { return }
            importing = true
            Task {
                defer { importing = false; photosItem = nil }
                do {
                    guard let file = try await item.loadTransferable(type: VideoFile.self) else {
                        onError("Could not load the selected video.")
                        return
                    }
                    picked = PickedVideo(url: file.url, name: file.url.lastPathComponent)
                } catch {
                    onError("Could not load video: \(error.localizedDescription)")
                }
            }
        }
        .accessibilityLabel(picked == nil ? "Choose video" : "Video: \(picked!.name)")
    }
}
