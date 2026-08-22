import Foundation

/// Thin async wrapper over the `git` CLI. Agent-agnostic. Returns structs, not
/// raw text. Shelling out (vs libgit2) matches the subprocess ethos and is easy
/// to debug. See DESIGN.md.
struct GitService: Sendable {
    var gitPath: String = AgentRegistry.resolveBinary("git") ?? "/usr/bin/git"

    struct WorktreeInfo: Sendable, Identifiable {
        var path: String
        var branch: String?
        var head: String?
        var id: String { path }
    }

    struct FileChange: Sendable, Identifiable {
        var path: String
        var status: String   // XY porcelain code, e.g. " M", "??", "A "
        var id: String { path }
    }

    // MARK: - Worktrees

    /// `git worktree add -b <branch> <path> <base>`
    func addWorktree(repo: URL, path: URL, branch: String, base: String) async throws {
        try await run(["worktree", "add", "-b", branch, path.path, base], cwd: repo)
    }

    /// `git worktree list --porcelain`
    func listWorktrees(repo: URL) async throws -> [WorktreeInfo] {
        let out = try await run(["worktree", "list", "--porcelain"], cwd: repo)
        var result: [WorktreeInfo] = []
        var current: WorktreeInfo?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let c = current { result.append(c) }
                current = WorktreeInfo(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch ".count))
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    /// `git worktree remove [--force] <path>`
    func removeWorktree(repo: URL, path: URL, force: Bool = false) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        try await run(args, cwd: repo)
    }

    // MARK: - Diff / status

    /// `git status --porcelain` for a worktree.
    func status(worktree: URL) async throws -> [FileChange] {
        let out = try await run(["status", "--porcelain"], cwd: worktree)
        return out.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let code = String(line.prefix(2))
            let path = String(line.dropFirst(3))
            return FileChange(path: path, status: code)
        }
    }

    /// Unified diff of the worktree against HEAD (`git diff HEAD`).
    func diff(worktree: URL, includeUntracked: Bool = false) async throws -> String {
        try await run(["diff", "HEAD"], cwd: worktree)
    }

    func currentBranch(worktree: URL) async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Runner

    @discardableResult
    private func run(_ args: [String], cwd: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = args
            process.currentDirectoryURL = cwd
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: outData, as: UTF8.self))
                } else {
                    continuation.resume(throwing: GitError.commandFailed(
                        args: args, code: proc.terminationStatus,
                        message: String(decoding: errData, as: UTF8.self)))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    enum GitError: Error, Sendable {
        case commandFailed(args: [String], code: Int32, message: String)
    }
}
