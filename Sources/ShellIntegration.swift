import AppKit

/// Links the `muskey` tool from the app bundle into `~/.local/bin`, and adds that folder to the PATH of the shells
/// that don't have it. The tool sits in Contents/Helpers so that the app's signature covers it as code.
enum ShellIntegration {
    static let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/muskey").path
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path
    static let link = (folder as NSString).appendingPathComponent("muskey")
    /// The link as people type it.
    static let shownLink = "~/.local/bin/muskey"

    /// The link exists and leads to this copy of the app, so a moved or replaced app shows Install again.
    static var installed: Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return false }
        return target == tool && FileManager.default.isExecutableFile(atPath: tool)
    }

    private static var shellConfigs: [(file: String, line: String, shell: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ("\(home)/.zshrc", "export PATH=\"$PATH:$HOME/.local/bin\"", "zsh"),
            ("\(home)/.bashrc", "export PATH=\"$PATH:$HOME/.local/bin\"", "bash"),
            ("\(home)/.config/fish/config.fish", "fish_add_path $HOME/.local/bin", "fish"),
        ]
    }

    /// The name of the login shell, like zsh, which a new Mac starts without a config file.
    private static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "zsh" }
        return (String(cString: shell) as NSString).lastPathComponent
    }

    /// The configs that lack `~/.local/bin`: those that exist and never mention it, and the login shell's when it is missing.
    private static var configsWithoutPath: [(file: String, line: String, shell: String)] {
        let login = loginShell
        return shellConfigs.filter { config in
            guard let text = try? String(contentsOfFile: config.file, encoding: .utf8) else {
                return config.shell == login && !FileManager.default.fileExists(atPath: config.file)
            }
            return !text.contains(".local/bin")
        }
    }

    static var needsPath: Bool { !configsWithoutPath.isEmpty }

    /// Makes the link, replacing one that leads elsewhere. Throws with the reason when it can't.
    static func install() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The tool is missing from Muskey.app"])
        }
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if (try? fm.attributesOfItem(atPath: link)) != nil { try fm.removeItem(atPath: link) }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: tool)
    }

    /// Adds `~/.local/bin` to each shell config that lacks it, at the end of the file that a link points to, and makes
    /// the login shell's config when it is missing.
    static func addToPath() throws {
        for config in configsWithoutPath {
            let url = URL(fileURLWithPath: config.file).resolvingSymlinksInPath()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + config.line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
