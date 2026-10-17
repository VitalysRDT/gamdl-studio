import Foundation
import Observation

/// Library observed by the UI; scanning happens off the main thread.
@MainActor
@Observable
final class LibraryStore {
    private(set) var albums: [LibraryAlbum] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var error: String?
    private(set) var root: URL?

    private var scanTask: Task<Void, Never>?

    var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    var totalSize: Int64 { albums.reduce(0) { $0 + $1.totalSize } }

    func recent(_ n: Int = 12) -> [LibraryAlbum] { Array(LibrarySort.recent.sort(albums).prefix(n)) }

    @discardableResult
    func refresh(root: URL) -> Task<Void, Never> {
        scanTask?.cancel()
        self.root = root
        isScanning = true
        let task = Task { [weak self] in
            let result: Result<[LibraryAlbum], Error> = await Task.detached(priority: .userInitiated) {
                Result { try LibraryScanner.scan(root: root) }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let albums):
                self.albums = albums
                self.error = nil
            case .failure(let error):
                self.error = error.localizedDescription
            }
            self.isScanning = false
            self.lastScan = .now
        }
        scanTask = task
        return task
    }

    /// Albums with a file written since `date`, i.e. what a job produced.
    func albums(modifiedSince date: Date) -> [LibraryAlbum] {
        albums.filter { album in album.tracks.contains { $0.modifiedAt >= date.addingTimeInterval(-2) } }
    }

    func album(at folder: URL) -> LibraryAlbum? {
        albums.first { $0.folder.standardizedFileURL.path == folder.standardizedFileURL.path }
    }
}
