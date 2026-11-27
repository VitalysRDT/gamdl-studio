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
        try open(script: script(running: gamdl), name: "gamdl-auth", directory: directory)
    }

    /// Writes `body` to `<name>.command` (owner-only) and opens it in Terminal.
    @discardableResult
    static func open(script body: String, name: String, directory: URL = AppSettings.applicationSupport, launch: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(name).command")
        let text = body.hasPrefix("#!") ? body : "#!/bin/sh\n# Opened by Gamdl Studio.\nset -e\n" + body + "\necho\necho 'Done. You can close this window and go back to Gamdl Studio.'\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        if launch { NSWorkspace.shared.open(file) }
        return file
    }
}
