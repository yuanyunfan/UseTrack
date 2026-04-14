import Foundation

/// Periodically scans Git repositories for new commits and records output metrics.
class GitWatcher {
    private let dbManager: DatabaseManager
    private var timer: Timer?
    private let scanInterval: TimeInterval
    private let repoPaths: [String]  // Paths to Git repositories to monitor
    private var lastCommitHashes: [String: String] = [:]  // repo path -> last known commit hash

    init(dbManager: DatabaseManager, repoPaths: [String]? = nil, scanInterval: TimeInterval = 300) {
        self.dbManager = dbManager
        self.scanInterval = scanInterval
        // Default: scan ~/ProjectRepo/
        self.repoPaths = repoPaths ?? GitWatcher.discoverRepos()
    }

    func start() {
        // Initial scan
        scanAll()

        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            self?.scanAll()
        }
    }

    func stop() {
        timer?.invalidate()
    }

    private func scanAll() {
        for path in repoPaths {
            scanRepo(at: path)
        }
    }

    private func scanRepo(at path: String) {
        // Get latest commit hash
        guard let currentHash = runGit(["rev-parse", "HEAD"], in: path) else { return }

        let lastHash = lastCommitHashes[path]

        if lastHash == nil {
            // First scan, just record the current hash
            lastCommitHashes[path] = currentHash
            return
        }

        if currentHash == lastHash { return }  // No new commits

        // Count new commits since last check
        guard let countStr = runGit(["rev-list", "--count", "\(lastHash!)..HEAD"], in: path),
              let count = Int(countStr) else { return }

        // Get line stats
        let diffStat = runGit(["diff", "--shortstat", "\(lastHash!)..HEAD"], in: path) ?? ""
        let (added, removed) = parseDiffStat(diffStat)

        // Record metrics
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        let today = df.string(from: Date())
        let repoName = URL(fileURLWithPath: path).lastPathComponent

        do {
            try dbManager.addOutputMetric(
                date: today, metricType: "git_commits",
                delta: Double(count), details: "{\"repo\": \"\(repoName)\"}"
            )
            try dbManager.addOutputMetric(
                date: today, metricType: "git_lines_added",
                delta: Double(added), details: "{\"repo\": \"\(repoName)\"}"
            )
            try dbManager.addOutputMetric(
                date: today, metricType: "git_lines_removed",
                delta: Double(removed), details: "{\"repo\": \"\(repoName)\"}"
            )
            print("[GitWatcher] \(repoName): \(count) commits, +\(added)/-\(removed) lines")
        } catch {
            print("[GitWatcher] Error: \(error)")
        }

        lastCommitHashes[path] = currentHash
    }

    private func runGit(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func parseDiffStat(_ stat: String) -> (added: Int, removed: Int) {
        // Parse "3 files changed, 120 insertions(+), 45 deletions(-)"
        var added = 0, removed = 0

        if let range = stat.range(of: #"(\d+) insertion"#, options: .regularExpression) {
            let numStr = stat[range].split(separator: " ").first ?? ""
            added = Int(numStr) ?? 0
        }
        if let range = stat.range(of: #"(\d+) deletion"#, options: .regularExpression) {
            let numStr = stat[range].split(separator: " ").first ?? ""
            removed = Int(numStr) ?? 0
        }

        return (added, removed)
    }

    /// Discover Git repositories under ~/ProjectRepo/
    static func discoverRepos() -> [String] {
        let basePath = NSHomeDirectory() + "/ProjectRepo"
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else { return [] }

        return contents.compactMap { name in
            let path = basePath + "/" + name
            var isDir: ObjCBool = false
            let gitDir = path + "/.git"
            if fm.fileExists(atPath: gitDir, isDirectory: &isDir), isDir.boolValue {
                return path
            }
            return nil
        }
    }
}
