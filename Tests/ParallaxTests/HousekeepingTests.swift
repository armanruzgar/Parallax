import XCTest
@testable import Parallax

final class HousekeepingTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("housekeeping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ path: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    func testOnlyOldStampedBackupsAreRemoved() throws {
        let backups = root.appendingPathComponent("ChatBackups")
        let old = try folder("ChatBackups/\(stamp(now - 20 * day))-local_a-1234abcd")
        let recent = try folder("ChatBackups/\(stamp(now - 2 * day))-local_b-1234abcd")
        let unstamped = try folder("ChatBackups/keep-me", modified: now - 100 * day)

        XCTAssertEqual(Housekeeping.pruneBackups(in: backups, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unstamped.path))
    }

    func testStaleBuildCachesAreRemovedAndRecentlyBuiltOnesKept() throws {
        let userData = root.appendingPathComponent("UserData")
        // Deepest first: creating a folder updates its parent's date.
        try folder("UserData/simulator-builds/aaa/DerivedData", modified: now - 30 * day)
        let stale = try folder("UserData/simulator-builds/aaa", modified: now - 30 * day)
        // The project folder itself is old, but a build log below it is fresh.
        try folder("UserData/simulator-builds/bbb/DerivedData/Logs", modified: now - day)
        try folder("UserData/simulator-builds/bbb/DerivedData", modified: now - 30 * day)
        let used = try folder("UserData/simulator-builds/bbb", modified: now - 30 * day)

        XCTAssertEqual(Housekeeping.pruneCaches(userData: [userData, root.appendingPathComponent("Missing")], now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path))
    }

    func testIdleVMImageIsRemovedAndRecentlyRunOneKept() throws {
        func bundle(_ space: String, diskUsed: Date) throws -> URL {
            let url = try folder("\(space)/UserData/vm_bundles/claudevm.bundle")
            let disk = url.appendingPathComponent("rootfs.img")
            try Data([1]).write(to: disk)
            try FileManager.default.setAttributes([.modificationDate: diskUsed], ofItemAtPath: disk.path)
            try FileManager.default.setAttributes([.modificationDate: now - 60 * day], ofItemAtPath: url.path)
            return url
        }
        let idle = try bundle("A", diskUsed: now - 5 * day)
        let active = try bundle("B", diskUsed: now - day)

        let spaces = ["A", "B"].map { root.appendingPathComponent("\($0)/UserData") }
        XCTAssertEqual(Housekeeping.pruneCaches(userData: spaces, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: idle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    }

    func testMeasureSplitsSpaceIntoPartsAndRemovingVMImageKeepsChats() throws {
        func file(_ path: String, bytes: Int) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try file("S/UserData/vm_bundles/claudevm.bundle/rootfs.img", bytes: 400_000)
        try file("S/UserData/ClaudeConfig/projects/-work/chat.jsonl", bytes: 100_000)
        try file("S/UserData/simulator-builds/aaa/DerivedData/x", bytes: 50_000)
        try file("S/UserData/Cache/y", bytes: 20_000)
        let space = root.appendingPathComponent("S"), id = UUID()

        let before = SpaceStorage.measure(spaceID: id, folder: space)
        XCTAssertGreaterThanOrEqual(before.vmImage, 400_000)
        XCTAssertGreaterThanOrEqual(before.chats, 100_000)
        XCTAssertGreaterThanOrEqual(before.buildCaches, 50_000)
        XCTAssertGreaterThanOrEqual(before.other, 20_000)
        XCTAssertEqual(before.total, before.vmImage + before.chats + before.buildCaches + before.other)

        try Housekeeping.removeVMImage(folder: space)
        let after = SpaceStorage.measure(spaceID: id, folder: space)
        XCTAssertEqual(after.vmImage, 0)
        XCTAssertEqual(after.chats, before.chats)
        XCTAssertTrue(FileManager.default.fileExists(atPath: space.appendingPathComponent("UserData/vm_bundles").path))
    }

    func testIdenticalFilesInClosedSpacesBecomeClonesAndOthersAreLeftAlone() throws {
        let size = 300_000
        func file(_ path: String, byte: UInt8, modified: Date) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: byte, count: size).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified, .posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
        let old = now - 10 * day
        let open = try file("A/UserData/ClaudeConfig/projects/-p/chat.jsonl", byte: 1, modified: old)
        let same = try file("B/UserData/ClaudeConfig/projects/-p/chat.jsonl", byte: 1, modified: old)
        let staged = try file("C/UserData/claude-code-sessions/a/o/imported-staging/x/chat.jsonl", byte: 1, modified: old)
        let different = try file("B/UserData/ClaudeConfig/projects/-p/other.jsonl", byte: 2, modified: old)
        let fresh = try file("C/UserData/ClaudeConfig/projects/-p/chat.jsonl", byte: 1, modified: now - 60)
        let elsewhere = try file("B/UserData/Cache/chat.jsonl", byte: 1, modified: old)
        let small = root.appendingPathComponent("B/UserData/ClaudeConfig/projects/-p/small.jsonl")
        try Data([1]).write(to: small)

        let spaces = ["A", "B", "C"].map { root.appendingPathComponent("\($0)/UserData") }
        let freed = Housekeeping.shareIdenticalFiles(userData: spaces, idle: Array(spaces.dropFirst()), now: now)

        XCTAssertEqual(freed, Int64(2 * size))
        let original = try XCTUnwrap(Housekeeping.firstBlock(open))
        XCTAssertEqual(Housekeeping.firstBlock(same), original)
        XCTAssertEqual(Housekeeping.firstBlock(staged), original)
        XCTAssertNotEqual(Housekeeping.firstBlock(different), original)
        XCTAssertNotEqual(Housekeeping.firstBlock(fresh), original, "A file changed in the last hour may still be being written")
        XCTAssertNotEqual(Housekeeping.firstBlock(elsewhere), original, "Only the listed folders are touched")
        for url in [same, staged] {
            XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 1, count: size))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            XCTAssertEqual(attributes[.modificationDate] as? Date, old)
        }
        XCTAssertEqual(try Data(contentsOf: different), Data(repeating: 2, count: size))
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
        // Nothing left to do the second time.
        XCTAssertEqual(Housekeeping.shareIdenticalFiles(userData: spaces, idle: Array(spaces.dropFirst()), now: now), 0)
    }

    func testFilesInOpenSpacesAreNeverReplaced() throws {
        func file(_ space: String) throws -> URL {
            let url = root.appendingPathComponent("\(space)/UserData/claude-code/1.0/claude")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 9, count: 300_000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now - 10 * day], ofItemAtPath: url.path)
            return url
        }
        let a = try file("A"), b = try file("B")
        let spaces = ["A", "B"].map { root.appendingPathComponent("\($0)/UserData") }
        XCTAssertEqual(Housekeeping.shareIdenticalFiles(userData: spaces, idle: [], now: now), 0)
        XCTAssertNotEqual(Housekeeping.firstBlock(a), Housekeeping.firstBlock(b))
    }
}
