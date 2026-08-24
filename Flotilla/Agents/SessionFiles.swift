import Foundation

/// Locates an agent's on-disk transcript for a session id. Prefers a directly
/// derivable path; falls back to scanning the agent's session root for a file
/// whose name contains the id. See docs/formats/*.md for the path patterns.
enum SessionFiles {
    static func locate(_ provider: AgentProvider, session: String, worktree: URL) -> URL? {
        if let direct = provider.sessionFileURL(session: session, worktree: worktree),
           FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let root = provider.sessionSearchRoot(worktree: worktree) else { return nil }
        return scan(root, containing: session)
    }

    /// Newest `.jsonl` under `root` whose filename contains `id`.
    private static func scan(_ root: URL, containing id: String) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var best: (url: URL, date: Date)?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.contains(id) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (url, date) }
        }
        return best?.url
    }
}
