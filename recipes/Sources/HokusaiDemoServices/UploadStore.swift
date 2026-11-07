import Foundation

/// Bounded, in-memory ownership of uploaded originals.
///
/// An upload id is an opaque random token for bytes held here. It is never a file name, so a client
/// cannot use it to reach the server's filesystem. Entries expire, the store has a byte budget, and
/// the oldest entries are evicted first, so an idle or abusive client cannot grow memory without bound.
public actor UploadStore {
    public struct Limits: Sendable {
        public var maxUploadBytes: Int
        public var maxTotalBytes: Int
        public var maxEntries: Int
        public var timeToLive: Duration
        public init(maxUploadBytes: Int = 25 * 1024 * 1024, maxTotalBytes: Int = 128 * 1024 * 1024, maxEntries: Int = 16, timeToLive: Duration = .seconds(600)) {
            self.maxUploadBytes = maxUploadBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxEntries = maxEntries
            self.timeToLive = timeToLive
        }
    }

    public enum StoreError: Error, Equatable {
        case tooLarge(limit: Int)
        case empty
    }

    private struct Entry {
        let data: Data
        var expires: ContinuousClock.Instant
        var lastUsed: ContinuousClock.Instant
    }

    public let limits: Limits
    private var entries: [String: Entry] = [:]
    private let clock = ContinuousClock()

    public init(limits: Limits = .init()) { self.limits = limits }

    /// Stores a copy of `data` and returns its id.
    public func put(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw StoreError.empty }
        guard data.count <= limits.maxUploadBytes else { throw StoreError.tooLarge(limit: limits.maxUploadBytes) }
        sweep()
        let now = clock.now
        // Make room: oldest first, by entry count and by byte budget.
        while entries.count >= limits.maxEntries || totalBytes + data.count > limits.maxTotalBytes, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries[oldest] = nil
        }
        let id = UUID().uuidString.lowercased()
        entries[id] = Entry(data: data, expires: now.advanced(by: limits.timeToLive), lastUsed: now)
        return id
    }

    /// The bytes for `id`, or `nil` if it never existed or has expired. Using an upload extends its life.
    public func get(_ id: String) -> Data? {
        sweep()
        guard var entry = entries[id] else { return nil }
        let now = clock.now
        entry.lastUsed = now
        entry.expires = now.advanced(by: limits.timeToLive)
        entries[id] = entry
        return entry.data
    }

    public func remove(_ id: String) { entries[id] = nil }

    public var count: Int { entries.count }
    public var totalBytes: Int { entries.values.reduce(0) { $0 + $1.data.count } }

    private func sweep() {
        let now = clock.now
        entries = entries.filter { $0.value.expires > now }
    }
}
