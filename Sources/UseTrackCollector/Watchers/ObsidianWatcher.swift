import Foundation

/// Monitors Obsidian vault for file changes and records word count metrics.
class ObsidianWatcher {
    private let dbManager: DatabaseManager
    private let vaultPath: String
    private var timer: Timer?
    private var lastFileState: [String: (wordCount: Int, modDate: Date)] = [:]  // file path -> cached state
    private let scanInterval: TimeInterval

    init(dbManager: DatabaseManager, vaultPath: String? = nil, scanInterval: TimeInterval = 300) {
        self.dbManager = dbManager
        self.vaultPath = vaultPath ?? (NSHomeDirectory() + "/Documents/NotionSync")
        self.scanInterval = scanInterval
    }

    func start() {
        // Initial scan to establish baseline
        initialScan()

        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            self?.checkChanges()
        }
    }

    func stop() {
        timer?.invalidate()
    }

    private func initialScan() {
        let files = findMarkdownFiles()
        let fm = FileManager.default
        for file in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if let content = try? String(contentsOfFile: file, encoding: .utf8) {
                lastFileState[file] = (wordCount: countWords(content), modDate: modDate)
            }
        }
        print("[ObsidianWatcher] Baseline: \(files.count) markdown files in vault")
    }

    private func checkChanges() {
        let files = findMarkdownFiles()
        var totalNewWords = 0
        var changedFiles: [String] = []
        let fm = FileManager.default

        for file in files {
            // Check modification date first (cheap stat vs expensive read)
            guard let attrs = try? fm.attributesOfItem(atPath: file),
                  let modDate = attrs[.modificationDate] as? Date else { continue }

            if let cached = lastFileState[file], cached.modDate == modDate {
                continue  // File unchanged, skip reading
            }

            // File changed or new — read and count words
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let currentCount = countWords(content)
            let previousCount = lastFileState[file]?.wordCount ?? 0

            if currentCount > previousCount {
                totalNewWords += currentCount - previousCount
                changedFiles.append(URL(fileURLWithPath: file).lastPathComponent)
            }

            lastFileState[file] = (wordCount: currentCount, modDate: modDate)
        }

        guard totalNewWords > 0 else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        let today = df.string(from: Date())
        let details = changedFiles.prefix(5).joined(separator: ", ")

        do {
            try dbManager.insertOutputMetric(
                date: today, metricType: "obsidian_words",
                value: Double(totalNewWords),
                details: "{\"files\": \"\(details)\"}"
            )
            print("[ObsidianWatcher] +\(totalNewWords) words in \(changedFiles.count) files")
        } catch {
            print("[ObsidianWatcher] Error: \(error)")
        }
    }

    private func findMarkdownFiles() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: vaultPath) else { return [] }

        var files: [String] = []
        while let element = enumerator.nextObject() as? String {
            if element.hasSuffix(".md") && !element.contains(".trash") {
                files.append(vaultPath + "/" + element)
            }
        }
        return files
    }

    private func countWords(_ text: String) -> Int {
        // Count Chinese characters + English words
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
