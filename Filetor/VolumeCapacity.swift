import Foundation

/// Byte counts for the mounted volume containing a directory (not the size of its contents).
nonisolated struct VolumeCapacity: Equatable, Sendable {
    let available: Int64
    let total: Int64

    init?(available: Int64?, total: Int64?) {
        guard let available, let total, total > 0, (0...total).contains(available) else { return nil }
        self.available = available
        self.total = total
    }

    static func read(at directory: URL) -> Self? {
        // A new URL avoids reusing cached resource values after a transfer or remount.
        let url = URL(fileURLWithPath: directory.path)
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                       .volumeIsInternalKey])
        let total = values?.volumeTotalCapacity.map(Int64.init)
        // Preserve the purgeable-space estimate on internal storage. External file
        // systems such as ExFAT may return zero for this estimate even with ample space.
        if values?.volumeIsInternal == true,
           let estimate = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           estimate > 0, let capacity = Self(available: estimate, total: total) { return capacity }
        if let capacity = Self(available: values?.volumeAvailableCapacity.map(Int64.init), total: total) { return capacity }
        guard let fs = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else { return nil }
        return Self(available: (fs[.systemFreeSize] as? NSNumber)?.int64Value,
                    total: (fs[.systemSize] as? NSNumber)?.int64Value)
    }

    @MainActor var statusText: String {
        let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return L10n.tr("\(free) available of \(size)")
    }
}
