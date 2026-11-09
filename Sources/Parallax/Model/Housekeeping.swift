import Foundation

/// Removes leftovers that only ever grow: old chat backups, and VM images and simulator builds Claude stopped using.
/// Also makes files that are the same in several spaces share their disk blocks.
enum Housekeeping {
    static let maxAge: TimeInterval = 14 * 86_400

    /// Deletes backup folders whose name stamp is older than `maxAge`. Folders without a readable stamp are kept.
    @discardableResult
    static func pruneBackups(in backups: URL, now: Date) -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        var removed = 0
        for folder in (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [] {
            guard let stamp = formatter.date(from: String(folder.lastPathComponent.prefix(20))),
                  now.timeIntervalSince(stamp) > maxAge,
                  (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// A VM image is about 11 GB per space and Claude fetches it again (1.2 GB) on demand, so it goes sooner.
    static let vmImageMaxAge: TimeInterval = 3 * 86_400

    /// Claude data that it rebuilds on demand, how deep to look for signs of use, and how long it may sit unused.
    /// `simulator-builds` holds Xcode DerivedData per project; `vm_bundles` holds the ~10 GB VM image,
    /// whose disk files change whenever the VM runs and which Claude downloads again when it's missing.
    static let caches: [(folder: String, depth: Int, maxAge: TimeInterval)] = [
        ("simulator-builds", 3, maxAge), ("vm_bundles", 1, vmImageMaxAge),
    ]

    /// Deletes items in each `caches` folder that weren't used within its age limit. Pass only spaces that aren't running.
    @discardableResult
    static func pruneCaches(userData folders: [URL], now: Date) -> Int {
        var removed = 0
        for userData in folders {
            for cache in caches {
                let parent = userData.appendingPathComponent(cache.folder, isDirectory: true)
                for item in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                    guard let used = lastModified(item, depth: cache.depth), now.timeIntervalSince(used) > cache.maxAge,
                          (try? FileManager.default.removeItem(at: item)) != nil else { continue }
                    removed += 1
                }
            }
        }
        return removed
    }

    /// Newest modification date of `url` and the folders and files up to `depth` levels below it.
    /// Xcode touches its Logs and Build folders on every build, so a shallow look is enough.
    private static func lastModified(_ url: URL, depth: Int) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate else { return nil }
        guard depth > 0, values.isDirectory == true, values.isSymbolicLink != true,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return date }
        return children.compactMap { lastModified($0, depth: depth - 1) }.reduce(date) { max($0, $1) }
    }
}

extension Housekeeping {
    /// Folders in a space's `UserData` where every space ends up with the same files:
    /// carried chats, their staged copies, and the Claude Code builds each space downloads for itself.
    static let sharedContent = ["ClaudeConfig/projects", "claude-code-sessions", "claude-code", "claude-code-vm"]
    static let sharedMinimumSize = 256 * 1024
    /// A file changed this recently may still be being written.
    static let sharedSettleTime: TimeInterval = 3600
    /// Held while a chat file is replaced, by this pass and by a chat carry-over, so neither undoes the other.
    static let rewriteLock = NSLock()

    /// Replaces files in `idle` spaces that are byte-for-byte equal to a file in another space with an APFS clone of it.
    /// Clones share disk blocks until one of them changes. `all` lists every space's `UserData`, `idle` those not running.
    /// Returns the bytes that no longer take their own space.
    @discardableResult
    static func shareIdenticalFiles(userData all: [URL], idle: [URL], now: Date) -> Int64 {
        struct Candidate { var url: URL; var writable: Bool; var modified: Date }
        let idle = Set(idle.map { $0.standardizedFileURL.path })
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var bySize: [Int: [Candidate]] = [:]
        for userData in Set(all.map(\.standardizedFileURL)) {
            for folder in sharedContent {
                let root = userData.appendingPathComponent(folder, isDirectory: true)
                guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
                for case let file as URL in files {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                          let size = values.fileSize, size >= sharedMinimumSize, let modified = values.contentModificationDate,
                          !file.lastPathComponent.hasSuffix(".tmp") else { continue }
                    bySize[size, default: []].append(Candidate(url: file, writable: idle.contains(userData.path), modified: modified))
                }
            }
        }
        var freed: Int64 = 0
        for (size, group) in bySize where group.count > 1 && group.contains(where: \.writable) {
            // Files that can't be replaced come first, so the others become clones of them.
            var kept: [(url: URL, block: off_t?)] = []
            for file in group.sorted(by: { ($0.writable ? 1 : 0, $0.url.path) < ($1.writable ? 1 : 0, $1.url.path) }) {
                let block = firstBlock(file.url)
                if let block, kept.contains(where: { $0.block == block }) { continue }
                guard file.writable, now.timeIntervalSince(file.modified) > sharedSettleTime,
                      let original = kept.first(where: { FileManager.default.contentsEqual(atPath: $0.url.path, andPath: file.url.path) }),
                      replace(file.url, withCloneOf: original.url) else {
                    kept.append((file.url, block))
                    continue
                }
                freed += Int64(size)
            }
        }
        return freed
    }

    /// Where the file's first byte sits on the disk. Two files with the same answer share their blocks.
    static func firstBlock(_ url: URL) -> off_t? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var map = log2phys(l2p_flags: 0, l2p_contigbytes: 4096, l2p_devoffset: 0)
        guard fcntl(descriptor, F_LOG2PHYS_EXT, &map) == 0, map.l2p_devoffset > 0 else { return nil }
        return map.l2p_devoffset
    }

    /// Keeps the file's own permissions and date. Gives up if either file changed while this ran.
    private static func replace(_ file: URL, withCloneOf original: URL) -> Bool {
        rewriteLock.withLock {
            var before = stat()
            guard lstat(file.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return false }
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            guard clonefile(original.path, temporary.path, 0) == 0 else { return false }
            var times = [before.st_atimespec, before.st_mtimespec]
            var after = stat()
            guard FileManager.default.contentsEqual(atPath: temporary.path, andPath: file.path),
                  chmod(temporary.path, before.st_mode & 0o7777) == 0, utimensat(AT_FDCWD, temporary.path, &times, 0) == 0,
                  lstat(file.path, &after) == 0, after.st_ino == before.st_ino, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  rename(temporary.path, file.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return false
            }
            return true
        }
    }
}

/// Disk use of one space's data folder, split into the parts worth knowing about.
struct SpaceStorage: Identifiable, Equatable, Sendable {
    var id: UUID
    var total: Int64 = 0
    var vmImage: Int64 = 0
    var chats: Int64 = 0
    var buildCaches: Int64 = 0
    var other: Int64 { max(0, total - vmImage - chats - buildCaches) }

    /// Sizes count each file in full, so chats that are APFS clones of another space's copy may use less.
    static func measure(spaceID: UUID, folder: URL) -> SpaceStorage {
        let userData = folder.appendingPathComponent("UserData", isDirectory: true)
        func size(_ path: String) -> Int64 { Housekeeping.size(of: userData.appendingPathComponent(path)) }
        return SpaceStorage(
            id: spaceID, total: Housekeeping.size(of: folder), vmImage: size("vm_bundles"),
            chats: size("ClaudeConfig/projects") + size("claude-code-sessions"), buildCaches: size("simulator-builds")
        )
    }
}

extension Housekeeping {
    /// Allocated bytes of a file or folder, without following symbolic links.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes a space's Claude VM image. Claude downloads it again when the space next needs it.
    static func removeVMImage(folder: URL) throws {
        let bundles = folder.appendingPathComponent("UserData/vm_bundles", isDirectory: true)
        for item in (try? FileManager.default.contentsOfDirectory(at: bundles, includingPropertiesForKeys: nil)) ?? [] {
            try FileManager.default.removeItem(at: item)
        }
    }
}
