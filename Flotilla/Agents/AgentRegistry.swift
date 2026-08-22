import Foundation

/// Looks up the provider for an agent and probes which CLIs are installed.
enum AgentRegistry {
    static func provider(for kind: AgentKind) -> AgentProvider {
        switch kind {
        case .claude: ClaudeAdapter()
        case .codex: CodexAdapter()
        case .pi: PiAdapter()
        }
    }

    /// Resolve a binary on PATH (and common install dirs), returning its path.
    static func resolveBinary(_ name: String) -> String? {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = pathEnv.split(separator: ":").map(String.init) + extra
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Which agents have a resolvable binary right now.
    static func installed() -> [AgentKind: String] {
        var result: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            if let path = resolveBinary(kind.defaultBinary) { result[kind] = path }
        }
        return result
    }
}
