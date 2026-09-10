import Foundation
import Combine
import UIKit

/// Where the backend lives and who we are to it.
struct TwinzoEndpoint: Equatable, Sendable {
    var baseURL: URL
    var projectID: UUID
    /// Bearer token. Held in the keychain by the caller, never written to the
    /// outbox file — a queue entry can sit on disk for days.
    var accessToken: String
}

enum SyncError: LocalizedError {
    case notConfigured
    case unauthorized
    /// The server rejected the payload itself. Retrying will not help.
    case rejected(status: Int, detail: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No project is configured. Sign in and pick a project before uploading."
        case .unauthorized:
            return "Sign-in has expired. Sign in again to upload this inspection."
        case .rejected(let status, let detail):
            return "The server rejected this upload (\(status)): \(detail)"
        case .transport(let detail):
            return detail
        }
    }

    /// Whether queueing another attempt could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .transport:        return true
        case .unauthorized:     return true   // a token refresh may fix it
        case .rejected:         return false  // the payload is the problem
        case .notConfigured:    return false
        }
    }
}

/// Uploads finished inspections, offline first.
///
/// Nothing here blocks the capture loop, and nothing is ever uploaded straight
/// from memory. Work goes to the outbox on disk the moment it is complete and is
/// drained whenever the network allows; a site with no signal is the normal case,
/// not the exception, and an inspection that only exists in RAM is one
/// backgrounded app away from being a wasted afternoon.
@MainActor
final class TwinzoAPI: ObservableObject {

    @Published private(set) var isUploading = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var poisonedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastUploadAt: Date?

    var endpoint: TwinzoEndpoint?

    private let outbox: SyncOutbox
    private let session: URLSession
    private let encoder = SyncCoding.makeEncoder()

    /// Stable per-install identifier, so the server can tell which device a
    /// replayed change came from. `identifierForVendor` resets when the last app
    /// from the vendor is deleted, which is exactly the right lifetime: a
    /// reinstall genuinely is a new client with an empty outbox.
    let deviceID: String

    init(outboxURL: URL? = nil, session: URLSession = .shared) {
        let url = outboxURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Twinzo/outbox.json")
        self.outbox = SyncOutbox(fileURL: url)
        self.session = session
        self.deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        refreshCounts()
    }

    // MARK: - Queueing

    /// Writes an upload to disk. Returns immediately; delivery is somebody
    /// else's problem and may be days away.
    func enqueue(_ upload: SessionUpload) {
        do {
            outbox.enqueue(try encoder.encode(upload))
            refreshCounts()
            Task { await drain() }
        } catch {
            // Encoding a value type we built ourselves should not fail. If it
            // somehow does, the operator has to hear about it now, while the scan
            // is still on the device and can be re-exported by hand.
            lastError = "Could not prepare the upload: \(error.localizedDescription)"
        }
    }

    // MARK: - Draining

    /// Sends whatever is due, one entry at a time, oldest first.
    ///
    /// Serial rather than concurrent on purpose. These are transactional writes
    /// that the server applies whole, the payloads are large, and site
    /// connectivity is thin enough that parallel uploads mostly succeed at
    /// starving each other.
    func drain() async {
        guard !isUploading, endpoint != nil else { return }
        isUploading = true
        defer {
            isUploading = false
            refreshCounts()
        }

        while let entry = outbox.nextDue() {
            do {
                try await send(entry.payload)
                outbox.markSucceeded(id: entry.id)
                lastUploadAt = Date()
                lastError = nil
            } catch let error as SyncError {
                outbox.markFailed(id: entry.id, error: error.localizedDescription)
                lastError = error.localizedDescription
                // Stop on the first failure. If the network is down, the next
                // entry will fail the same way, and burning through the whole
                // queue only inflates every entry's attempt count toward the
                // poison threshold for one outage.
                return
            } catch {
                outbox.markFailed(id: entry.id, error: error.localizedDescription)
                lastError = error.localizedDescription
                return
            }
            refreshCounts()
        }
    }

    private func send(_ payload: Data) async throws {
        guard let endpoint else { throw SyncError.notConfigured }

        var request = URLRequest(
            url: endpoint.baseURL
                .appendingPathComponent("projects")
                .appendingPathComponent(endpoint.projectID.uuidString)
                .appendingPathComponent("scan-sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload
        // Long enough for a large payload over a site connection, short enough
        // that a dead link is noticed before the screen locks.
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: payload)
        } catch {
            throw SyncError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.transport("Unrecognised response from the server.")
        }

        switch http.statusCode {
        case 200...299, 409:
            // 409 means the server already applied this client_change_id. That is
            // a success from the device's point of view — the work is stored, the
            // acknowledgement was simply lost on the way back — and treating it
            // as a failure would leave the entry retrying forever.
            return
        case 401, 403:
            throw SyncError.unauthorized
        case 400, 422:
            throw SyncError.rejected(status: http.statusCode,
                                     detail: Self.detail(from: data))
        default:
            // 5xx and anything else: assume the server will recover.
            throw SyncError.transport(
                "Server returned \(http.statusCode). Will retry.")
        }
    }

    private static func detail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String ?? object["error"] as? String
        else { return String(decoding: data.prefix(200), as: UTF8.self) }
        return message
    }

    func retryPoisoned() {
        outbox.retryPoisoned()
        refreshCounts()
        Task { await drain() }
    }

    private func refreshCounts() {
        pendingCount = outbox.pendingCount
        poisonedCount = outbox.poisoned.count
    }
}
