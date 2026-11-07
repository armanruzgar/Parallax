import XCTest
@testable import Parallax

final class SidebarTests: ChatFixture {
    func testSyncCarriesChatsWithoutChangingSidebarLayout() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b, account: "acctB", org: "orgB")
        for (space, scope, group, modified) in [(a, "acct/org", "new", 2_000.0), (b, "acctB/orgB", "old", 1_000.0)] {
            let prefs: [String: Any] = [
                "dframe-group-scopes": [scope: ["groups": [["id": group, "name": group]]]],
                "dframe-code-sections": [scope: ["sections": [["id": group, "kind": "manual"]]]],
            ]
            let config = space.sessions.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json")
            try JSONSerialization.data(withJSONObject: ["preferences": ["epitaxyPrefs": prefs]]).write(to: config)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: config.path)
        }
        let config = b.sessions.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json")
        let before = try Data(contentsOf: config)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)

        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(ClaudeChats.scan([b]).map(\.id), [chatID])
        XCTAssertEqual(try ClaudeChats.normalizedTranscript(Data(contentsOf: native(b)), cwds: [cwd]),
                       try ClaudeChats.normalizedTranscript(Data(contentsOf: native(a)), cwds: [cwd]))
        XCTAssertEqual(try Data(contentsOf: config), before)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertFalse(backupNames.contains { $0.contains("-sidebar-") })
    }

    func testActivityTimeCatchesUpWhenMessagesMatch() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 500)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual((try record(b)["lastActivityAt"] as? NSNumber)?.doubleValue, 500)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(try transfer(to: a, spaces: [a, b]).kind, .upToDate)
    }

    func testTurnTimeCatchesUpWhenMessagesMatch() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 500, extra: ["lastTurnEdgeAt": 900])
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 500)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 900)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 500)
        XCTAssertNil(carried["lastFocusedAt"])
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(try transfer(to: a, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testActivityTimeRaisesStaleTargetTurnTime() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 600)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100, extra: ["lastTurnEdgeAt": 100])
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 600, "An existing turn key stays even when it matches activity")
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 600)
        XCTAssertEqual(try XCTUnwrap(ClaudeChats.scan([b]).first).sidebarOrderAt, 600)
    }

    func testActivityWithoutATurnDoesNotRaiseSidebarOrder() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 800, extra: ["lastTurnEdgeAt": 300])
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 300)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        let carried = try record(b)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 800)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 300)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
    }

    func testNewMessagesCarryTurnTime() throws {
        let a = space("A"), b = space("B")
        let messages = [line("user", "one"), line("assistant", "two")]
        try writeNativeChat(in: a, lines: messages, lastActivity: 650, extra: ["lastTurnEdgeAt": 700])
        try writeNativeChat(in: b, lines: [messages[0]], lastActivity: 100)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .update)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 700)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 650)
        XCTAssertEqual(try ClaudeChats.normalizedTranscript(Data(contentsOf: native(b)), cwds: [cwd]),
                       try ClaudeChats.normalizedTranscript(Data(contentsOf: native(a)), cwds: [cwd]))
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
    }

    func testAddedChatCarriesTurnTime() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 650, extra: ["lastTurnEdgeAt": 700])
        _ = try namespace(b)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .add)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(result.transferred, 1)
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 700)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 650)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
    }

    func testChatListUsesClaudeSidebarOrder() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100, extra: ["lastTurnEdgeAt": 900])
        try writeNativeChat(in: a, lines: [line("user", "two", sessionID: "second")], lastActivity: 800,
                            chatID: "local_second", cliSessionID: "second")
        try writeNativeChat(in: a, lines: [line("user", "three", sessionID: "third")], lastActivity: 1000,
                            chatID: "local_third", cliSessionID: "third", lastFocused: 2000, extra: ["lastTurnEdgeAt": 200])
        let chats = ClaudeChats.scan([a])
        XCTAssertEqual(chats.map(\.id), [chatID, "local_second", "local_third"])
        XCTAssertEqual(chats.map(\.sidebarOrderAt), [900, 800, 200])
        XCTAssertEqual(chats.map(\.sidebarOrder), [900.0, 800, 200].map { Date(timeIntervalSince1970: $0 / 1000) })
        XCTAssertEqual(chats[0].lastActivity, Date(timeIntervalSince1970: 0.1))
    }

    func testSidebarOrderIncludesTheTargetsCopy() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one"), line("assistant", "two")],
                            lastActivity: 650, extra: ["lastTurnEdgeAt": 700])
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 600, extra: ["lastTurnEdgeAt": 900])
        let prepared = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(prepared.kind, .update)
        XCTAssertEqual(prepared.source.spaceID, a.spaceID)
        XCTAssertEqual(prepared.sidebarOrderAt, 900)
        XCTAssertEqual(try XCTUnwrap(ClaudeChats.scan([a, b]).first).sidebarOrderAt, 900)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        let carried = try record(b)
        XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, 900)
        XCTAssertEqual(carried["lastActivityAt"] as? Double, 650)
    }

    func testApplyKeepsDestinationTimesChangedAfterPrepare() throws {
        for kind in [ChatTransfer.Kind.updateMetadata, .update] {
            for hasTurn in [false, true] {
                let a = space("A-\(kind)-\(hasTurn)"), b = space("B-\(kind)-\(hasTurn)")
                let messages = [line("user", "one")] + (kind == .update ? [line("assistant", "two")] : [])
                try writeNativeChat(in: a, lines: messages, lastActivity: 500, lastFocused: 400, extra: ["lastTurnEdgeAt": 700])
                try writeNativeChat(in: b, lines: [messages[0]], lastActivity: 100, lastFocused: 100)
                let prepared = try transfer(to: b, spaces: [a, b])
                XCTAssertEqual(prepared.kind, kind)
                try editRecord(b) {
                    $0["lastActivityAt"] = 800
                    if hasTurn { $0["lastTurnEdgeAt"] = 900 }
                    $0["lastFocusedAt"] = 1000
                }
                try ClaudeChats.apply(prepared, backups: backups)
                let carried = try record(b)
                XCTAssertEqual(carried["lastActivityAt"] as? Double, 800)
                XCTAssertEqual(carried["lastFocusedAt"] as? Double, 1000)
                XCTAssertEqual(carried["lastTurnEdgeAt"] as? Double, hasTurn ? 900 : nil)
                XCTAssertEqual(try XCTUnwrap(ClaudeChats.scan([b]).first).sidebarOrderAt, hasTurn ? 900 : 800)
            }
        }
    }
}
