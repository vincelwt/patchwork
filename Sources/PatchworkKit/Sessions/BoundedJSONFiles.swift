import Darwin
import Foundation

/// A newest-first, size-bounded catalog for small JSON sidecar directories. Directory order is
/// unspecified, so filtering after `prefix` can hide a newly written file behind stale entries.
public struct BoundedJSONFile: Sendable {
    public struct Fingerprint: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let modifiedAt: TimeInterval
        public let statusChangedAt: TimeInterval
        public let size: Int64
    }

    public let url: URL
    public let path: String
    public let fingerprint: Fingerprint
    public let isSymbolicLink: Bool
}

public enum BoundedJSONFiles {
    public struct DirectoryFingerprint: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let modifiedAt: TimeInterval
        public let statusChangedAt: TimeInterval
    }

    /// A complete, bounded view of one sidecar directory. Callers retain this value between
    /// scans so an unchanged directory can refresh the known files directly instead of paying
    /// for URL enumeration and path normalization on every polling tick.
    public struct Catalog: Sendable {
        public let files: [BoundedJSONFile]
        fileprivate let directoryPath: String
        fileprivate let directoryFingerprint: DirectoryFingerprint?
        fileprivate let completeForRevalidation: Bool
        fileprivate let stable: Bool
    }

    public struct CatalogScan: Sendable {
        public let catalog: Catalog
        /// Exposed primarily as a deterministic performance-test seam.
        public let reusedDirectoryListing: Bool
    }

    public static func directoryFingerprint(_ directory: URL) -> DirectoryFingerprint? {
        var info = stat()
        guard stat(directory.standardizedFileURL.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DirectoryFingerprint(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modifiedAt: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            statusChangedAt: Double(info.st_ctimespec.tv_sec)
                + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        )
    }

    public static func newest(
        in directory: URL,
        limit: Int,
        maxBytes: Int
    ) -> [BoundedJSONFile] {
        scan(in: directory, limit: limit, maxBytes: maxBytes).catalog.files
    }

    /// Refreshes a previous catalog without enumerating the directory when it is safe to do so.
    /// Every retained file is still `stat`ed, which preserves in-place writes and symlink target
    /// replacement. A catalog that omitted or skipped any JSON candidate is always rediscovered
    /// because that file may have changed in place and become an eligible newest entry.
    public static func scan(
        in directory: URL,
        limit: Int,
        maxBytes: Int,
        previous: Catalog? = nil
    ) -> CatalogScan {
        let directory = directory.standardizedFileURL
        let directoryPath = directory.path
        let fingerprintBefore = directoryFingerprint(directory)
        if limit > 0, let previous,
           previous.directoryPath == directoryPath,
           previous.directoryFingerprint == fingerprintBefore,
           previous.completeForRevalidation,
           previous.stable,
           let refreshed = refreshKnown(previous.files, maxBytes: maxBytes) {
            let fingerprintAfter = directoryFingerprint(directory)
            if fingerprintAfter == fingerprintBefore {
                return CatalogScan(
                    catalog: Catalog(
                        files: refreshed,
                        directoryPath: directoryPath,
                        directoryFingerprint: fingerprintAfter,
                        completeForRevalidation: true,
                        stable: true
                    ),
                    reusedDirectoryListing: true
                )
            }
        }

        let discoveryBefore = directoryFingerprint(directory)
        let discovery = discoverNewest(in: directory, limit: limit, maxBytes: maxBytes)
        let discoveryAfter = directoryFingerprint(directory)
        return CatalogScan(
            catalog: Catalog(
                files: discovery.files,
                directoryPath: directoryPath,
                directoryFingerprint: discoveryAfter,
                completeForRevalidation: discovery.completeForRevalidation,
                stable: discoveryBefore == discoveryAfter
            ),
            reusedDirectoryListing: false
        )
    }

    private static func discoverNewest(
        in directory: URL,
        limit: Int,
        maxBytes: Int
    ) -> (files: [BoundedJSONFile], completeForRevalidation: Bool) {
        guard limit > 0, maxBytes >= 0 else { return ([], false) }
        var completeForRevalidation = true
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                completeForRevalidation = false
                return true
            }
        ) else {
            return ([], directoryFingerprint(directory) == nil)
        }

        let newestFirst: (BoundedJSONFile, BoundedJSONFile) -> Bool = {
            if $0.fingerprint.modifiedAt != $1.fingerprint.modifiedAt {
                return $0.fingerprint.modifiedAt > $1.fingerprint.modifiedAt
            }
            return $0.path < $1.path
        }
        let trimAt = limit > Int.max / 2 ? Int.max : limit * 2
        var retained: [BoundedJSONFile] = []
        retained.reserveCapacity(min(trimAt, 1_000))
        var validFileCount = 0
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "json" else { continue }
            let path = url.standardizedFileURL.path
            var linkInfo = stat()
            guard lstat(path, &linkInfo) == 0 else {
                completeForRevalidation = false
                continue
            }
            let isSymbolicLink = linkInfo.st_mode & S_IFMT == S_IFLNK
            var targetInfo = stat()
            let targetResolved = !isSymbolicLink || stat(path, &targetInfo) == 0
            let info = isSymbolicLink ? targetInfo : linkInfo
            // Follow symlinks so a stable `.json` link can point at an atomically replaced
            // payload. The target inode remains part of the fingerprint, so replacement still
            // invalidates a cached decode.
            guard targetResolved, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0,
                  Int64(info.st_size) <= Int64(maxBytes) else {
                completeForRevalidation = false
                continue
            }
            let modifiedAt = Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            let statusChangedAt = Double(info.st_ctimespec.tv_sec)
                + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
            validFileCount += 1
            retained.append(BoundedJSONFile(
                url: url,
                path: path,
                fingerprint: .init(
                    device: UInt64(info.st_dev),
                    inode: UInt64(info.st_ino),
                    modifiedAt: modifiedAt,
                    statusChangedAt: statusChangedAt,
                    size: Int64(info.st_size)
                ),
                isSymbolicLink: isSymbolicLink
            ))
            if retained.count >= trimAt {
                retained.sort(by: newestFirst)
                retained.removeLast(retained.count - limit)
            }
        }
        retained.sort(by: newestFirst)
        if retained.count > limit { retained.removeLast(retained.count - limit) }
        return (retained, completeForRevalidation && validFileCount <= limit)
    }

    private static func refreshKnown(
        _ files: [BoundedJSONFile], maxBytes: Int
    ) -> [BoundedJSONFile]? {
        guard maxBytes >= 0 else { return nil }
        var refreshed: [BoundedJSONFile] = []
        refreshed.reserveCapacity(files.count)
        for file in files {
            guard let file = refresh(file, maxBytes: maxBytes) else { return nil }
            refreshed.append(file)
        }
        refreshed.sort {
            if $0.fingerprint.modifiedAt != $1.fingerprint.modifiedAt {
                return $0.fingerprint.modifiedAt > $1.fingerprint.modifiedAt
            }
            return $0.path < $1.path
        }
        return refreshed
    }

    private static func refresh(
        _ file: BoundedJSONFile, maxBytes: Int
    ) -> BoundedJSONFile? {
        var linkInfo = stat()
        guard lstat(file.path, &linkInfo) == 0 else { return nil }
        let isSymbolicLink = linkInfo.st_mode & S_IFMT == S_IFLNK
        var targetInfo = stat()
        let targetResolved = !isSymbolicLink || stat(file.path, &targetInfo) == 0
        let info = isSymbolicLink ? targetInfo : linkInfo
        guard targetResolved, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              Int64(info.st_size) <= Int64(maxBytes) else { return nil }
        let modifiedAt = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let statusChangedAt = Double(info.st_ctimespec.tv_sec)
            + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return BoundedJSONFile(
            url: file.url,
            path: file.path,
            fingerprint: .init(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                modifiedAt: modifiedAt,
                statusChangedAt: statusChangedAt,
                size: Int64(info.st_size)
            ),
            isSymbolicLink: isSymbolicLink
        )
    }

    /// Reads at most `maxBytes + 1`, so a file that grows or is replaced after cataloging cannot
    /// turn a small-sidecar scan into an unbounded allocation.
    public static func read(_ file: BoundedJSONFile, maxBytes: Int) -> Data? {
        guard maxBytes >= 0, maxBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1),
              data.count <= maxBytes else { return nil }
        return data
    }
}
