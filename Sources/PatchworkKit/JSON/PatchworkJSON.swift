import Foundation

/// The wire date format for every timestamp in `docs/daemon-api.md`: ISO 8601 with fractional
/// seconds, UTC. Shared by every model in this package so the daemon, the CLI, and the app
/// agree byte-for-byte.
public enum PatchworkDate {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Timestamps without a fractional component (hand-written test fixtures, other tools)
    /// still decode instead of failing the whole payload.
    static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func string(from date: Date) -> String { formatter.string(from: date) }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }
}

/// One `JSONEncoder`/`JSONDecoder` pair for every payload the control plane reads or writes,
/// so date formatting and forward-compatible decoding behave identically whether the caller is
/// the daemon serving a request, the CLI reading a response, or a store reading a JSON file
/// from disk.
///
/// Forward compatibility here rests on three things working together: (1) Swift's synthesized
/// `Decodable` already ignores JSON keys a struct does not declare, so additive fields are free;
/// (2) every model in this package gives its own evolving/optional fields explicit defaults via
/// `decodeIfPresent`, so a field a newer writer adds — or an older one omits — never fails the
/// whole decode; (3) every wire enum (roles, trigger kinds, statuses, event names) keeps an
/// `other(String)` case populated by a custom `init(from:)` instead of throwing on a value it
/// does not recognise yet. See `TolerantRawRepresentable` for the shared plumbing behind (3).
public enum PatchworkJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PatchworkDate.string(from: date))
        }
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = PatchworkDate.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }()
}

/// Backing storage for a `Codable` enum that must never fail to decode: known cases map to a
/// raw value, anything else is preserved verbatim in `.other` instead of throwing. Every wire
/// enum a client might receive (never one only a client *sends*) is built this way.
public protocol TolerantRawRepresentable: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    static var knownCases: [Self] { get }
    static func other(_ rawValue: String) -> Self
}

public extension TolerantRawRepresentable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownCases.first { $0.rawValue == raw } ?? Self.other(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PatchworkFileError: Error, LocalizedError, Sendable {
    case notFound(URL)
    case decodingFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(url): "No file at \(url.path)."
        case let .decodingFailed(url, reason): "Could not decode \(url.path): \(reason)"
        }
    }
}

/// Atomic JSON file I/O with the permissions `docs/daemon-api.md` requires for everything under
/// `Application Support/Patchwork`: the directory `0700`, every file in it `0600`. Every
/// control-plane store (settings, schedules, the token, run history) goes through this so the
/// permission story is enforced in exactly one place.
public enum PatchworkFile {
    /// Creates `directory` if needed and (re)asserts `0700`, including on a directory the app's
    /// older, less strict `AppPersistence` may already have created.
    @discardableResult
    public static func ensureDirectory(_ directory: URL) throws -> URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }

    /// Encodes `value` and writes it to a temp file beside `url`, then renames into place, so a
    /// reader never observes a half-written schedules.json or daemon.json. `rename(2)` on the
    /// same volume is atomic; the temp file always lives in the same directory to guarantee that.
    public static func writeAtomic<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = PatchworkJSON.encoder) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let data = try encoder.encode(value)
        try writeAtomic(data, to: url)
    }

    public static func writeAtomic(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = PatchworkJSON.decoder) throws -> T {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw PatchworkFileError.notFound(url)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PatchworkFileError.decodingFailed(url, String(describing: error))
        }
    }

    public static func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = PatchworkJSON.decoder) -> T? {
        try? read(type, from: url, decoder: decoder)
    }
}
