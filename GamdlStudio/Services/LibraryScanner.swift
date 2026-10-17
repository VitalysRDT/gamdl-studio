import Foundation

/// Walks gamdl's output folder and groups files by album.
///
/// File system only, no tag reading: with ~900 tracks, opening every m4a
/// for its metadata would freeze the UI for several seconds. Artwork is
/// loaded later, on demand, by `ArtworkCache`.
enum LibraryScanner {
    static let mediaExtensions: Set<String> = ["m4a", "mp4", "m4v"]
    static let lyricsExtensions = ["lrc", "srt", "ttml"]
    static let coverNames = ["Cover.jpg", "Cover.png", "cover.jpg", "cover.png", "folder.jpg"]

    /// "01 Title", "2-05 Title" (disc-track), or just "Title".
    private static let fileNamePattern = TextPatterns.regex(#"^(?:(\d+)-)?(\d+)\s+(.+)$"#)

    static func parseFileName(_ base: String) -> (disc: Int?, track: Int?, title: String) {
        guard let g = fileNamePattern.captures(in: base), let title = g[3] else { return (nil, nil, base) }
        return (g[1].flatMap(Int.init), g[2].flatMap(Int.init), title)
    }

    static func scan(root: URL) throws -> [LibraryAlbum] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var byFolder: [URL: [URL]] = [:]
        for case let url as URL in enumerator {
            guard mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
            byFolder[url.deletingLastPathComponent().standardizedFileURL, default: []].append(url)
        }

        let rootComponents = root.standardizedFileURL.pathComponents
        return byFolder.map { folder, files in
            let tracks = files.map { file -> LibraryTrack in
                let values = try? file.resourceValues(forKeys: Set(keys))
                let base = file.deletingPathExtension().lastPathComponent
                let parsed = parseFileName(base)
                let lyrics = lyricsExtensions
                    .map { file.deletingPathExtension().appendingPathExtension($0) }
                    .first { fm.fileExists(atPath: $0.path) }
                return LibraryTrack(
                    url: file,
                    title: parsed.title,
                    trackNumber: parsed.track,
                    discNumber: parsed.disc,
                    size: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    lyricsURL: lyrics
                )
            }
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0, $0.title) < ($1.discNumber ?? 1, $1.trackNumber ?? 0, $1.title) }

            let relative = Array(folder.pathComponents.dropFirst(rootComponents.count))
            let (category, artist) = classify(relative)
            let cover = coverNames.map { folder.appending(path: $0) }.first { fm.fileExists(atPath: $0.path) }

            return LibraryAlbum(
                folder: folder,
                title: relative.last ?? folder.lastPathComponent,
                artist: artist,
                category: category,
                tracks: tracks,
                coverFile: cover
            )
        }
    }

    /// Infers the folder kind from its path relative to the root.
    static func classify(_ relative: [String]) -> (LibraryAlbum.Category, String?) {
        guard let first = relative.first else { return (.album, nil) }
        switch first {
        case "Compilations": return (.compilation, nil)
        case "Playlists": return (.playlist, relative.count > 2 ? relative[1] : nil)
        default: return (.album, relative.count >= 2 ? first : nil)
        }
    }
}
