//  AgentAccess.swift — Settings ▸ Agents' switch and the command it installs
//  (RFC-026 §6).
//
//  **Off by default, and read at every call.** The switch is the person's
//  consent for another program to edit their frames, so it is not cached by
//  a running MCP server: turning it off in Settings refuses the very next
//  tool call, without restarting the agent that holds the server.

import Foundation

enum AgentAccess {
    static let key = Session.uiKey + "agentAccess"

    static var enabled: Bool {
        get {
            // A long-running server must see a change another process made.
            UserDefaults.standard.synchronize()
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static let refusal = "Command line and agent access is off. Turn it on in SpektraLab ▸ Settings ▸ Agents."

    /// The app's own executable: what the MCP configuration names, and what
    /// the installed command runs.
    static var executable: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    /// Where Install puts the command. `~/.local/bin` needs no administrator
    /// password and is on the PATH of most shells set up for developer tools.
    static var installURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/spektralab")
    }

    /// The command is a two-line script, not a symlink to the executable.
    /// Run through a symlink, the executable's path is the link's, so
    /// `Bundle.main` would not find the app around it — and with it the
    /// engine's resources and the defaults domain this switch lives in.
    static var script: String {
        """
        #!/bin/sh
        # SpektraLab command line (RFC-026). Installed by Settings ▸ Agents.
        exec '\(executable.replacingOccurrences(of: "'", with: "'\\''"))' cli "$@"
        """ + "\n"
    }

    /// Whether the installed command is ours and points at this app.
    static var installState: InstallState {
        guard let text = try? String(contentsOf: installURL, encoding: .utf8) else { return .absent }
        return text == script ? .current : .other
    }

    enum InstallState { case absent, current, other }

    /// Write the script. Replaces only a script this app wrote before (a
    /// previous install pointing at another copy of the app); anything else at
    /// that path is someone else's file and is left alone.
    static func install() throws {
        let fm = FileManager.default
        if let text = try? String(contentsOf: installURL, encoding: .utf8),
           !text.contains("Installed by Settings ▸ Agents") {
            throw AgentError.refused("\(installURL.path) exists and is not SpektraLab's; it was left alone.")
        }
        try fm.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: installURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
    }

    static func uninstall() throws {
        guard installState != .absent else { return }
        guard let text = try? String(contentsOf: installURL, encoding: .utf8),
              text.contains("Installed by Settings ▸ Agents") else {
            throw AgentError.refused("\(installURL.path) is not SpektraLab's; it was left alone.")
        }
        try FileManager.default.removeItem(at: installURL)
    }

    /// The configuration lines Settings shows with a Copy button.
    static var claudeCodeCommand: String {
        "claude mcp add spektralab -- '\(executable)' mcp"
    }

    static var desktopConfig: String {
        let v: JSONValue = ["mcpServers": ["spektralab": ["command": .string(executable), "args": ["mcp"]]]]
        return v.text(pretty: true)
    }
}
