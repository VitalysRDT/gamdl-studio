import Foundation

/// Access to files in `GamdlStudioTests/Fixtures`, read straight from the
/// source tree (they are reference data, not copied into the test bundle).
enum Fixture {
    static var directory: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }
}
