import Foundation

/// One emoji's usage tally, keyed on the base (untoned) glyph.
struct FrequentEmoji: Codable, Hashable, Sendable {
    let glyph: String
    var count: Int
    var lastUsed: Date
}

/// Usage counts as a capped JSON file, feeding the grid's "Frequently Used".
@MainActor
@Observable
final class FrequentEmojiStore {
    private static let cap = 300

    private let fileURL: URL

    private(set) var records: [FrequentEmoji]

    /// The empty-query grid re-reads `top()` every render, so this sorts once per tally.
    @ObservationIgnored private var sortedMemo = Memo<Int, [String]>()
    private(set) var revision = 0

    init(fileURL: URL = AppPaths.applicationSupport().appendingPathComponent("emoji-frequency.json")) {
        self.fileURL = fileURL

        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([FrequentEmoji].self, from: data)
        {
            records = decoded
        } else {
            records = []
        }
    }

    func record(_ glyph: String) {
        revision &+= 1
        if let index = records.firstIndex(where: { $0.glyph == glyph }) {
            records[index].count += 1
            records[index].lastUsed = Date()
        } else {
            records.append(FrequentEmoji(glyph: glyph, count: 1, lastUsed: Date()))
        }
        if records.count > Self.cap {
            // Evict the least-used, oldest tallies so the file stays bounded.
            records.sort { $0.count != $1.count ? $0.count > $1.count : $0.lastUsed > $1.lastUsed }
            records.removeLast(records.count - Self.cap)
        }
        persist()
    }

    /// Replaces the tallies wholesale from a backup, under the same cap `record` enforces.
    func replace(_ imported: [FrequentEmoji]) {
        revision &+= 1
        records = Array(
            imported
                .filter { !$0.glyph.isEmpty && $0.count > 0 }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastUsed > $1.lastUsed }
                .prefix(Self.cap))
        persist()
    }

    /// Most-used glyphs (recency breaks ties), newest habits first.
    func top(_ n: Int = 16) -> [String] {
        let sorted = sortedMemo.value(for: revision) {
            records
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lastUsed > $1.lastUsed }
                .map(\.glyph)
        }
        return Array(sorted.prefix(n))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Ordered user favorites, persisted separately from learned usage so neither can rewrite the other.
@MainActor
@Observable
final class PinnedEmojiStore {
    /// The catalog is currently smaller; this only bounds a malformed or hand-edited file.
    private static let cap = 3_000

    private let fileURL: URL
    private(set) var glyphs: [String]
    private(set) var revision = 0
    @ObservationIgnored var onPersistenceFailure: (() -> Void)?

    init(fileURL: URL = AppPaths.applicationSupport().appendingPathComponent("emoji-pinned.json")) {
        self.fileURL = fileURL
        let decoded =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        glyphs = Self.normalized(decoded)
    }

    func index(of glyph: String) -> Int? {
        glyphs.firstIndex(of: glyph)
    }

    func toggle(_ glyph: String) {
        guard !glyph.isEmpty else { return }
        if let index = glyphs.firstIndex(of: glyph) {
            glyphs.remove(at: index)
        } else {
            glyphs.append(glyph)
        }
        didChange()
    }

    /// Restores authored pins from a backup, preserving order while dropping invalid duplicates.
    func replace(_ imported: [String]) {
        glyphs = Self.normalized(imported)
        didChange()
    }

    @discardableResult
    func move(_ glyph: String, by delta: Int) -> Bool {
        guard let source = glyphs.firstIndex(of: glyph) else { return false }
        let destination = source + delta
        guard glyphs.indices.contains(destination) else { return false }
        glyphs.swapAt(source, destination)
        didChange()
        return true
    }

    private func didChange() {
        revision &+= 1
        do {
            let data = try JSONEncoder().encode(glyphs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            onPersistenceFailure?()
        }
    }

    private static func normalized(_ glyphs: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(min(glyphs.count, cap))
        for glyph in glyphs where !glyph.isEmpty && seen.insert(glyph).inserted {
            result.append(glyph)
            if result.count == cap { break }
        }
        return result
    }
}
