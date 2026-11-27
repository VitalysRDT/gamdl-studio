import AppKit
import Foundation

/// Opens `gamdl auth` in Terminal. Signing the wrapper in to an Apple Account
/// takes an Apple ID, a password and often a two-factor code: gamdl asks for
/// them itself, in the terminal, and the app never sees them.
enum TerminalLauncher {
    /// A `.command` file Terminal runs when opened.
    static func script(running gamdl: URL) -> String {
        """
        #!/bin/sh
        # Opened by Gamdl Studio: choose "Wrapper", then sign in with your Apple Account.
        clear
        exec \(GamdlCommand.shellQuote(gamdl.path)) auth
        """
    }

    @discardableResult
    static func openAuth(gamdl: URL, directory: URL = AppSettings.applicationSupport) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "gamdl-auth.command")
        try script(running: gamdl).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
        return file
    }
}
