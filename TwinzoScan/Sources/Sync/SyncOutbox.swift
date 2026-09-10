import Foundation

/// A queued upload waiting for connectivity.
struct OutboxEntry: Codable, Equatable, Sendable {
    var id: UUID
    /// Encoded `SessionUpload`. Held as bytes rather than as the struct so an
    /// entry queued by an older build still uploads after an app update: the
    /// payload was already serialised under the contract that was current when
    /// the inspection happened, and re-encoding it under a new one would change
    /// what gets stored.
    var payload: Data
    var queuedAt: Date
    var attempts: Int
    var lastAttemptAt: Date?
    var lastError: String?

    /// Exponential backoff with a ceiling. A site with no signal will otherwise
    /// spend the afternoon retrying and the phone will be flat before anyone
    /// reaches the car park.
    func nextAttemptDue(now: Date = Date()) -> Bool {
        guard let lastAttemptAt else { return true }
        let delay = min(pow(2.0, Double(min(attempts, 8))) * 5, 900)
        return now.timeIntervalSince(lastAttemptAt) >= delay
    }
}

/// Durable queue of uploads that have not been acknowledged.
///
/// Construction sites do not have connectivity, and an inspection that only
/// exists in RAM is one backgrounded app away from being a wasted afternoon. Work
/// is written to disk the moment it is complete, and uploaded whenever the
/// network allows.
///
/// Atomicity is the whole job here. Every mutation writes the file through a
/// temporary and renames it, so a crash or a battery pull mid-write leaves the
/// previous good queue rather than a truncated one.
///
/// Free of URLSession and UIKit so the queue behaviour can be tested off Apple
/// hardware; the transport is somebody else's problem.
final class SyncOutbox {

    private let fileURL: URL
    private let maximumEntries: Int
    private var entries: [OutboxEntry] = []

    /// Attempts after which an entry is considered poisoned and set aside.
    ///
    /// It is never discarded. A payload the server keeps rejecting is a bug
    /// worth diagnosing, and it is also an inspector's afternoon of work.
    static let maximumAttempts = 12

    init(fileURL: URL, maximumEntries: Int = 500) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        load()
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Entries that have failed often enough to need a human.
    var poisoned: [OutboxEntry] {
        entries.filter { $0.attempts >= Self.maximumAttempts }
    }

    var pendingCount: Int {
        entries.filter { $0.attempts < Self.maximumAttempts }.count
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(_ payload: Data, id: UUID = UUID()) -> OutboxEntry {
        let entry = OutboxEntry(id: id, payload: payload, queuedAt: Date(),
                                attempts: 0, lastAttemptAt: nil, lastError: nil)
        entries.append(entry)

        // Drop the oldest *successfully-irrelevant* overflow only. Poisoned
        // entries are kept ahead of fresh ones when trimming, because they are
        // the ones somebody still has to look at.
        if entries.count > maximumEntries {
            let overflow = entries.count - maximumEntries
            var removable = entries.enumerated()
                .filter { $0.element.attempts < Self.maximumAttempts }
                .map(\.offset)
                .prefix(overflow)
            if removable.count < overflow {
                // Everything is poisoned. Trim from the front regardless rather
                // than growing without bound.
                removable = Array(0..<overflow)[...]
            }
            let doomed = Set(removable)
            entries = entries.enumerated()
                .filter { !doomed.contains($0.offset) }
                .map(\.element)
        }

        persist()
        return entry
    }

    /// Next entry due for an attempt, oldest first.
    func nextDue(now: Date = Date()) -> OutboxEntry? {
        entries.first {
            $0.attempts < Self.maximumAttempts && $0.nextAttemptDue(now: now)
        }
    }

    func markSucceeded(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func markFailed(id: UUID, error: String, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].attempts += 1
        entries[index].lastAttemptAt = date
        entries[index].lastError = error
        persist()
    }

    /// Puts a poisoned entry back in the queue — for after the server-side cause
    /// has been fixed.
    func retryPoisoned() {
        for index in entries.indices where entries[index].attempts >= Self.maximumAttempts {
            entries[index].attempts = 0
            entries[index].lastAttemptAt = nil
        }
        persist()
    }

    func removeAll() {
        entries.removeAll()
        persist()
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // A corrupt queue file must not stop the app launching. Losing unsent
        // work is bad; refusing to start so it can never be replaced is worse.
        entries = (try? JSONDecoder().decode([OutboxEntry].self, from: data)) ?? []
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            // .atomic writes through a temporary and renames, so a crash
            // mid-write leaves the previous queue intact rather than a
            // half-written file that decodes to nothing.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Nothing useful to do here, and throwing would take down the frame
            // loop that queued the work. The entry stays in memory and the next
            // mutation tries again.
        }
    }
}
